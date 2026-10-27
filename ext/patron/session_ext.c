/*
 * Patron: libcurl bindings for Ruby.
 *
 * One Patron::Session owns one CURLM (multi handle), one template easy handle that
 * every request is duplicated from, and one CURLSH that carries cookies, DNS entries
 * and TLS sessions across requests. The multi handle owns the connection cache, which
 * is what gives a Session connection reuse between requests.
 *
 * A request is driven by curl_multi_perform() while holding the GVL, so every libcurl
 * callback (write, header, progress, debug) is ordinary Ruby-safe code, and by
 * curl_multi_poll() with the GVL released. Ruby interrupts the poll through the
 * unblocking function, which calls curl_multi_wakeup(); that is what makes Thread#kill,
 * Thread#raise, Timeout and interpreter exit return promptly from any phase of a
 * transfer, including DNS and connect.
 *
 * Requires Ruby >= 3.3 and libcurl >= 7.81.0.
 */
#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/ractor.h>
#include <ruby/encoding.h>
#include <ruby/io.h>

#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>

#include <curl/curl.h>

#if LIBCURL_VERSION_NUM < 0x075100
#error "Patron requires libcurl 7.81.0 or newer"
#endif

#define INTERRUPT_ABORT 1
#define INTERRUPT_DOWNLOAD_OVERFLOW 2

/* How long one curl_multi_poll() may sleep. libcurl wakes us earlier on socket activity,
 * on its own timers, and on curl_multi_wakeup(); this is only the upper bound. */
#define POLL_TIMEOUT_MS 1000

#define BODY_BUFFER_INITIAL_CAPACITY (16 * 1024)
#define HEADER_BUFFER_INITIAL_CAPACITY 1024

static VALUE mPatron;
static VALUE mProxyType;
static VALUE cSession;
static VALUE cRequest;
static VALUE ePatronError;
static VALUE eUnsupportedProtocol;
static VALUE eUnsupportedSSLVersion;
static VALUE eUnsupportedHTTPVersion;
static VALUE eURLFormatError;
static VALUE eHostResolutionError;
static VALUE eConnectionFailed;
static VALUE ePartialFileError;
static VALUE eTimeoutError;
static VALUE eTooManyRedirects;
static VALUE eAborted;
static VALUE eDownloadLimitExceeded;
static VALUE eClientCertificateError;

/* Frozen, Ractor-shareable lookup tables exposed as Patron::Request::SSL_VERSIONS and
 * Patron::Request::HTTP_VERSIONS: version name => libcurl constant. */
static VALUE hSSLVersions;
static VALUE hHTTPVersions;

#define REQUEST_ATTRIBUTES(X) \
  X(action) X(action_name) X(headers) X(url) X(timeout) X(connect_timeout) \
  X(dns_cache_timeout) X(low_speed_time) X(low_speed_limit) X(max_redirects) \
  X(proxy) X(proxy_type) X(credentials) X(auth_type) X(ignore_content_length) \
  X(insecure) X(ssl_version) X(http_version) X(ssl_cert) X(ssl_cert_type) \
  X(ssl_key) X(ssl_key_password) X(cacert) X(buffer_size) X(download_byte_limit) \
  X(progress_callback) X(automatic_content_encoding) X(force_ipv4) \
  X(upload_data) X(file_name) X(multipart)

#define DECLARE_ID(name) static ID id_##name;
REQUEST_ATTRIBUTES(DECLARE_ID)
#undef DECLARE_ID

static ID id_to_path, id_to_s, id_response_class, id_default_response_charset;
static ID id_get, id_post, id_put, id_patch, id_delete, id_head;
static ID id_ivar_curl_code;
static ID id_url_kw, id_status_kw, id_redirect_count_kw, id_header_data_kw, id_body_kw,
          id_default_charset_kw, id_timings_kw;

struct patron_session {
  /* Lives as long as the Session object */
  VALUE self;                         /* back-pointer for write barriers, never marked */
  CURLM *multi;
  CURL *base;                         /* template; every request is a curl_easy_duphandle() of it */
  CURLSH *share;
  pthread_mutex_t share_locks[CURL_LOCK_DATA_LAST];
  pid_t pid;                          /* handles must not be reused across fork() */
  VALUE debug_io;                     /* IO receiving CURLOPT_VERBOSE output, or nil */

  /* Per request, torn down in cleanup() */
  CURL *easy;
  curl_mime *mime;
  struct curl_slist *headers;
  FILE *download_file;
  FILE *request_body_file;
  char error_buf[CURL_ERROR_SIZE];
  curl_off_t download_byte_limit;
  VALUE progress_proc;
  VALUE upload_data;                  /* pinned while libcurl reads it through CURLOPT_POSTFIELDS */
  VALUE header_buf;                   /* binary String receiving the raw headers */
  VALUE body_buf;                     /* binary String receiving the body, or nil when downloading to a file */

  /* A callback may not let a Ruby exception unwind through libcurl's frames. The tag and
   * errinfo are parked here, the transfer is aborted, and perform() re-raises afterwards. */
  int pending_tag;
  VALUE pending_errinfo;

  volatile sig_atomic_t interrupt;
  volatile sig_atomic_t busy;
};

/*----------------------------------------------------------------------------*/
/* TypedData                                                                  */

static void session_free(void *ptr) {
  struct patron_session *s = ptr;
  int i;

  /* A transfer cannot be in flight here: perform() keeps self on the stack. */
  if (s->multi) curl_multi_cleanup(s->multi);
  if (s->base) curl_easy_cleanup(s->base);
  if (s->share) curl_share_cleanup(s->share);
  for (i = 0; i < CURL_LOCK_DATA_LAST; i++) pthread_mutex_destroy(&s->share_locks[i]);
  ruby_xfree(s);
}

static void session_mark(void *ptr) {
  struct patron_session *s = ptr;

  rb_gc_mark_movable(s->debug_io);
  rb_gc_mark_movable(s->progress_proc);
  rb_gc_mark_movable(s->header_buf);
  rb_gc_mark_movable(s->body_buf);
  rb_gc_mark_movable(s->pending_errinfo);
  /* libcurl holds RSTRING_PTR() of this one for the whole transfer, and an embedded
   * String keeps its bytes inside the object slot, so it must not be moved. */
  rb_gc_mark(s->upload_data);
}

static void session_compact(void *ptr) {
  struct patron_session *s = ptr;

  s->debug_io = rb_gc_location(s->debug_io);
  s->progress_proc = rb_gc_location(s->progress_proc);
  s->header_buf = rb_gc_location(s->header_buf);
  s->body_buf = rb_gc_location(s->body_buf);
  s->pending_errinfo = rb_gc_location(s->pending_errinfo);
}

static size_t session_memsize(const void *ptr) {
  /* The Strings account for themselves; libcurl's own allocations are not visible. */
  return sizeof(struct patron_session);
}

/* RUBY_TYPED_EMBEDDABLE is deliberately not used: libcurl keeps pointers into this struct
 * (CURLOPT_XFERINFODATA, CURLOPT_ERRORBUFFER, CURLOPT_DEBUGDATA, the write/header userdata)
 * and an embedded struct moves under compaction. */
static const rb_data_type_t patron_session_data_type = {
  .wrap_struct_name = "Patron::Session",
  .function = {
    .dmark = session_mark,
    .dfree = session_free,
    .dsize = session_memsize,
    .dcompact = session_compact,
  },
  .flags = RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY
#ifdef RUBY_TYPED_THREAD_SAFE_FREE
           /* dfree only touches handles owned by this object */
           | RUBY_TYPED_THREAD_SAFE_FREE
#endif
  ,
};

/* Every entry point refreshes the back-pointer: the Session object itself may have been
 * moved by compaction since the last call. Within a call it is on the C stack and pinned,
 * which is what makes `s->self` safe to use from the libcurl callbacks. */
static struct patron_session *get_session(VALUE self) {
  struct patron_session *s;
  TypedData_Get_Struct(self, struct patron_session, &patron_session_data_type, s);
  s->self = self;
  return s;
}

#define SESSION_WRITE(s, field, value) RB_OBJ_WRITE((s)->self, &(s)->field, (value))

/*----------------------------------------------------------------------------*/
/* Errors                                                                     */

static VALUE error_class_for(CURLcode code) {
  switch (code) {
    case CURLE_UNSUPPORTED_PROTOCOL:  return eUnsupportedProtocol;
    case CURLE_URL_MALFORMAT:         return eURLFormatError;
    case CURLE_COULDNT_RESOLVE_HOST:  return eHostResolutionError;
    case CURLE_COULDNT_CONNECT:       return eConnectionFailed;
    case CURLE_PARTIAL_FILE:          return ePartialFileError;
    case CURLE_OPERATION_TIMEDOUT:    return eTimeoutError;
    case CURLE_TOO_MANY_REDIRECTS:    return eTooManyRedirects;
    case CURLE_ABORTED_BY_CALLBACK:   return eAborted;
    case CURLE_SSL_CERTPROBLEM:       return eClientCertificateError;
    default:                          return ePatronError;
  }
}

NORETURN(static void raise_curl_error(VALUE klass, CURLcode code, const char *message));
static void raise_curl_error(VALUE klass, CURLcode code, const char *message) {
  VALUE exc;

  if (!message || !*message) message = curl_easy_strerror(code);
  exc = rb_exc_new_cstr(klass, message);
  rb_ivar_set(exc, id_ivar_curl_code, INT2NUM((int)code));
  rb_exc_raise(exc);
}

/* curl_easy_setopt() only fails for options the installed libcurl cannot honour; that must
 * surface instead of silently running the request with defaults. */
#define setopt_or_raise(handle, option, value) do { \
  CURLcode setopt_rc_ = curl_easy_setopt((handle), (option), (value)); \
  if (setopt_rc_ != CURLE_OK) raise_curl_error(ePatronError, setopt_rc_, NULL); \
} while (0)

/*----------------------------------------------------------------------------*/
/* Deferred exceptions from inside libcurl callbacks                          */

static void park_exception(struct patron_session *s, int tag) {
  if (s->pending_tag) return;
  s->pending_tag = tag;
  SESSION_WRITE(s, pending_errinfo, rb_errinfo());
  s->interrupt = INTERRUPT_ABORT;
}

NORETURN(static void reraise_parked(struct patron_session *s));
static void reraise_parked(struct patron_session *s) {
  int tag = s->pending_tag;
  VALUE errinfo = s->pending_errinfo;

  s->pending_tag = 0;
  SESSION_WRITE(s, pending_errinfo, Qnil);
  rb_set_errinfo(errinfo);
  rb_jump_tag(tag);
}

/*----------------------------------------------------------------------------*/
/* libcurl callbacks. All of them run with the GVL held, from curl_multi_perform(). */

struct append_args {
  VALUE str;
  const char *ptr;
  size_t len;
};

static VALUE append_protected(VALUE arg) {
  struct append_args *a = (struct append_args *)arg;
  rb_str_cat(a->str, a->ptr, (long)a->len);
  return Qnil;
}

static size_t append_to_string(struct patron_session *s, VALUE str, const char *ptr, size_t len) {
  struct append_args args = { str, ptr, len };
  int tag = 0;

  rb_protect(append_protected, (VALUE)&args, &tag);
  if (tag) {
    park_exception(s, tag);
    return 0;
  }
  return len;
}

static size_t body_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct patron_session *s = userdata;
  size_t len = size * nmemb;

  if (s->download_file) {
    if (fwrite(ptr, 1, len, s->download_file) != len) return 0;
    return len;
  }
  return append_to_string(s, s->body_buf, ptr, len);
}

static size_t header_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct patron_session *s = userdata;
  return append_to_string(s, s->header_buf, ptr, size * nmemb);
}

static size_t file_read_cb(char *buffer, size_t size, size_t nitems, void *userdata) {
  FILE *fp = userdata;
  return fread(buffer, 1, size * nitems, fp);
}

struct progress_args {
  struct patron_session *s;
  curl_off_t dltotal, dlnow, ultotal, ulnow;
};

static VALUE progress_protected(VALUE arg) {
  struct progress_args *a = (struct progress_args *)arg;
  VALUE argv[4] = { LL2NUM(a->dltotal), LL2NUM(a->dlnow), LL2NUM(a->ultotal), LL2NUM(a->ulnow) };
  return rb_proc_call_with_block(a->s->progress_proc, 4, argv, Qnil);
}

/* Non-zero return aborts the transfer with CURLE_ABORTED_BY_CALLBACK. */
static int xferinfo_cb(void *userdata, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) {
  struct patron_session *s = userdata;

  if (s->interrupt) return 1;

  if (s->download_byte_limit > 0 && (dltotal > s->download_byte_limit || dlnow > s->download_byte_limit)) {
    s->interrupt = INTERRUPT_DOWNLOAD_OVERFLOW;
    return 1;
  }

  if (!NIL_P(s->progress_proc)) {
    struct progress_args args = { s, dltotal, dlnow, ultotal, ulnow };
    int tag = 0;
    VALUE result = rb_protect(progress_protected, (VALUE)&args, &tag);

    if (tag) {
      park_exception(s, tag);
      return 1;
    }
    /* Only an explicit false aborts; a callback that happens to end in nil keeps going. */
    if (result == Qfalse) {
      s->interrupt = INTERRUPT_ABORT;
      return 1;
    }
  }
  return 0;
}

struct debug_args {
  VALUE io;
  const char *prefix;
  const char *data;
  size_t len;
};

static VALUE debug_protected(VALUE arg) {
  struct debug_args *a = (struct debug_args *)arg;
  VALUE line = rb_str_buf_new((long)(a->len + 2));
  rb_str_cat_cstr(line, a->prefix);
  rb_str_cat(line, a->data, (long)a->len);
  rb_io_write(a->io, line);
  return Qnil;
}

/* Mirrors what libcurl itself prints with CURLOPT_VERBOSE: informational text and the
 * headers in both directions, never the payload. */
static int debug_cb(CURL *handle, curl_infotype type, char *data, size_t len, void *userdata) {
  struct patron_session *s = userdata;
  const char *prefix;
  struct debug_args args;
  int tag = 0;

  if (NIL_P(s->debug_io)) return 0;

  switch (type) {
    case CURLINFO_TEXT:       prefix = "* "; break;
    case CURLINFO_HEADER_IN:  prefix = "< "; break;
    case CURLINFO_HEADER_OUT: prefix = "> "; break;
    default:                  return 0;
  }

  args.io = s->debug_io;
  args.prefix = prefix;
  args.data = data;
  args.len = len;
  rb_protect(debug_protected, (VALUE)&args, &tag);
  if (tag) park_exception(s, tag);
  return 0;
}

static void share_lock_cb(CURL *handle, curl_lock_data data, curl_lock_access access, void *userptr) {
  struct patron_session *s = userptr;
  pthread_mutex_lock(&s->share_locks[data]);
}

static void share_unlock_cb(CURL *handle, curl_lock_data data, void *userptr) {
  struct patron_session *s = userptr;
  pthread_mutex_unlock(&s->share_locks[data]);
}

/*----------------------------------------------------------------------------*/
/* Handle lifecycle                                                           */

static void init_handles(struct patron_session *s) {
  int i;

  for (i = 0; i < CURL_LOCK_DATA_LAST; i++) pthread_mutex_init(&s->share_locks[i], NULL);

  s->share = curl_share_init();
  s->multi = curl_multi_init();
  s->base = curl_easy_init();
  if (!s->share || !s->multi || !s->base) {
    if (s->base) curl_easy_cleanup(s->base);
    if (s->multi) curl_multi_cleanup(s->multi);
    if (s->share) curl_share_cleanup(s->share);
    s->base = NULL; s->multi = NULL; s->share = NULL;
    rb_memerror();
  }
  s->pid = getpid();

  curl_share_setopt(s->share, CURLSHOPT_LOCKFUNC, share_lock_cb);
  curl_share_setopt(s->share, CURLSHOPT_UNLOCKFUNC, share_unlock_cb);
  curl_share_setopt(s->share, CURLSHOPT_USERDATA, s);
  curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_COOKIE);
  curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
  curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
  curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_PSL);

  /* The multi handle owns the connection cache. Multiplexing costs nothing with one
   * transfer at a time and is ready for concurrent transfers later. */
  curl_multi_setopt(s->multi, CURLMOPT_PIPELINING, CURLPIPE_MULTIPLEX);

  curl_easy_setopt(s->base, CURLOPT_SHARE, s->share);
  curl_easy_setopt(s->base, CURLOPT_WRITEFUNCTION, body_write_cb);
  curl_easy_setopt(s->base, CURLOPT_WRITEDATA, s);
  curl_easy_setopt(s->base, CURLOPT_HEADERFUNCTION, header_write_cb);
  curl_easy_setopt(s->base, CURLOPT_HEADERDATA, s);
  curl_easy_setopt(s->base, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(s->base, CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(s->base, CURLOPT_XFERINFOFUNCTION, xferinfo_cb);
  curl_easy_setopt(s->base, CURLOPT_XFERINFODATA, s);
  curl_easy_setopt(s->base, CURLOPT_DEBUGFUNCTION, debug_cb);
  curl_easy_setopt(s->base, CURLOPT_DEBUGDATA, s);
  curl_easy_setopt(s->base, CURLOPT_ERRORBUFFER, s->error_buf);

  /* Never let a URL or a redirect take us to gopher, smtp, file and friends. */
#if LIBCURL_VERSION_NUM >= 0x075500
  curl_easy_setopt(s->base, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(s->base, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
#else
  curl_easy_setopt(s->base, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
  curl_easy_setopt(s->base, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#endif
}

/* A forked child must not use connections it shares with the parent. The inherited
 * handles are abandoned rather than cleaned up, since cleaning up would shut down
 * TLS sessions on sockets the parent is still using. */
static void ensure_handles_for_this_process(struct patron_session *s) {
  if (s->pid == getpid()) return;
  s->multi = NULL;
  s->base = NULL;
  s->share = NULL;
  init_handles(s);
  /* Cookie jar and debug settings live on the base handle; the Ruby side re-applies them. */
  rb_funcall(s->self, rb_intern("reapply_base_options"), 0);
}

static VALUE session_alloc(VALUE klass) {
  struct patron_session *s;
  VALUE obj = TypedData_Make_Struct(klass, struct patron_session, &patron_session_data_type, s);

  s->self = obj;
  s->debug_io = Qnil;
  s->progress_proc = Qnil;
  s->upload_data = Qnil;
  s->header_buf = Qnil;
  s->body_buf = Qnil;
  s->pending_errinfo = Qnil;
  init_handles(s);
  return obj;
}

/*----------------------------------------------------------------------------*/
/* Module functions                                                           */

/*
 * Returns the version string of the libcurl in use, e.g. "libcurl/8.7.1 OpenSSL/3.3.0".
 *
 * @return [String]
 */
static VALUE libcurl_version(VALUE klass) {
  return rb_str_new_cstr(curl_version());
}

/*
 * Returns the version of the libcurl Patron was compiled against.
 *
 * @return [Array<Integer>] major, minor and patch
 */
static VALUE libcurl_version_exact(VALUE klass) {
  return rb_ary_new_from_args(3, INT2FIX(LIBCURL_VERSION_MAJOR), INT2FIX(LIBCURL_VERSION_MINOR), INT2FIX(LIBCURL_VERSION_PATCH));
}

/*
 * Describes the libcurl in use at runtime.
 *
 * @return [Hash] `:version`, `:ssl_version`, `:libz_version` Strings (the latter two may be nil)
 *   and `:features`, an Array of Symbols such as `:ssl`, `:http2`, `:http3`, `:asynchdns`, `:threadsafe`
 */
static VALUE libcurl_features(VALUE klass) {
  curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  VALUE features = rb_ary_new();
  VALUE result = rb_hash_new();

#define FEATURE(flag, name) if (info->features & (flag)) rb_ary_push(features, ID2SYM(rb_intern(name)))
  FEATURE(CURL_VERSION_SSL, "ssl");
  FEATURE(CURL_VERSION_IPV6, "ipv6");
  FEATURE(CURL_VERSION_LIBZ, "libz");
  FEATURE(CURL_VERSION_ASYNCHDNS, "asynchdns");
  FEATURE(CURL_VERSION_HTTP2, "http2");
  FEATURE(CURL_VERSION_HTTP3, "http3");
  FEATURE(CURL_VERSION_BROTLI, "brotli");
  FEATURE(CURL_VERSION_UNIX_SOCKETS, "unix_sockets");
#ifdef CURL_VERSION_ZSTD
  FEATURE(CURL_VERSION_ZSTD, "zstd");
#endif
#ifdef CURL_VERSION_THREADSAFE
  FEATURE(CURL_VERSION_THREADSAFE, "threadsafe");
#endif
#undef FEATURE

  rb_hash_aset(result, ID2SYM(rb_intern("version")), rb_str_new_cstr(info->version));
  rb_hash_aset(result, ID2SYM(rb_intern("ssl_version")), info->ssl_version ? rb_str_new_cstr(info->ssl_version) : Qnil);
  rb_hash_aset(result, ID2SYM(rb_intern("libz_version")), info->libz_version ? rb_str_new_cstr(info->libz_version) : Qnil);
  rb_hash_aset(result, ID2SYM(rb_intern("features")), features);
  return result;
}

/*
 * URL-escapes a String using libcurl.
 *
 * @param value [String]
 * @return [String] the escaped string
 */
static VALUE session_escape(VALUE self, VALUE value) {
  VALUE string = StringValue(value);
  char *escaped = curl_easy_escape(NULL, RSTRING_PTR(string), rb_long2int(RSTRING_LEN(string)));
  VALUE result;

  if (!escaped) rb_raise(ePatronError, "libcurl could not escape the string");
  result = rb_usascii_str_new_cstr(escaped);
  curl_free(escaped);
  return result;
}

/*
 * URL-unescapes a String using libcurl. The result is binary, since percent-escapes can
 * encode arbitrary bytes.
 *
 * @param value [String]
 * @return [String] the unescaped string
 */
static VALUE session_unescape(VALUE self, VALUE value) {
  VALUE string = StringValue(value);
  int outlen = 0;
  char *unescaped = curl_easy_unescape(NULL, RSTRING_PTR(string), rb_long2int(RSTRING_LEN(string)), &outlen);
  VALUE result;

  if (!unescaped) rb_raise(ePatronError, "libcurl could not unescape the string");
  result = rb_str_new(unescaped, outlen);
  curl_free(unescaped);
  return result;
}

/*----------------------------------------------------------------------------*/
/* Request configuration                                                      */

static VALUE request_attr(VALUE request, ID id) {
  return rb_funcallv(request, id, 0, NULL);
}

static int header_name_is(VALUE name, const char *expected) {
  long len = (long)strlen(expected);
  long i;
  const char *p;

  if (RSTRING_LEN(name) != len) return 0;
  p = RSTRING_PTR(name);
  for (i = 0; i < len; i++) {
    if (rb_tolower((unsigned char)p[i]) != rb_tolower((unsigned char)expected[i])) return 0;
  }
  return 1;
}

static int string_contains(VALUE str, const char *needle) {
  const char *haystack = RSTRING_PTR(str);
  long len = RSTRING_LEN(str);
  long needle_len = (long)strlen(needle);
  long i;

  for (i = 0; i + needle_len <= len; i++) {
    if (memcmp(haystack + i, needle, (size_t)needle_len) == 0) return 1;
  }
  return 0;
}

static int each_http_header(VALUE key, VALUE value, VALUE self) {
  struct patron_session *s = get_session(self);
  VALUE name = rb_obj_as_string(key);
  VALUE line;

  /* "Accept-Encoding: gzip" also asks libcurl to inflate the response for us. */
  if (header_name_is(name, "Accept-Encoding") && string_contains(rb_obj_as_string(value), "gzip")) {
    setopt_or_raise(s->easy, CURLOPT_ACCEPT_ENCODING, "gzip");
  }

  line = rb_sprintf("%"PRIsVALUE": %"PRIsVALUE, name, value);
  s->headers = curl_slist_append(s->headers, StringValueCStr(line));
  return ST_CONTINUE;
}

static curl_mimepart *add_mime_part(struct patron_session *s, VALUE key) {
  curl_mimepart *part;
  VALUE name = rb_obj_as_string(key);

  if (!s->mime) s->mime = curl_mime_init(s->easy);
  part = curl_mime_addpart(s->mime);
  if (!part) rb_memerror();
  curl_mime_name(part, StringValueCStr(name));
  return part;
}

static int each_mime_value(VALUE key, VALUE value, VALUE self) {
  struct patron_session *s = get_session(self);
  VALUE str = rb_obj_as_string(value);
  curl_mimepart *part = add_mime_part(s, key);

  /* curl_mime_data() copies, so the String may be collected right after this call. */
  curl_mime_data(part, RSTRING_PTR(str), (size_t)RSTRING_LEN(str));
  return ST_CONTINUE;
}

static int each_mime_file(VALUE key, VALUE value, VALUE self) {
  struct patron_session *s = get_session(self);
  VALUE path = rb_obj_as_string(value);
  curl_mimepart *part = add_mime_part(s, key);

  FilePathValue(path);
  if (curl_mime_filedata(part, StringValueCStr(path)) != CURLE_OK) {
    rb_raise(rb_eArgError, "Unable to read file for multipart upload: %"PRIsVALUE, path);
  }
  return ST_CONTINUE;
}

static FILE *open_file(VALUE filename, const char *mode) {
  FILE *handle;

  FilePathValue(filename);
  handle = fopen(StringValueCStr(filename), mode);
  if (!handle) rb_sys_fail_str(filename);
  return handle;
}

static void set_request_body_from_file(struct patron_session *s, VALUE path) {
  struct stat st;

  s->request_body_file = open_file(path, "rb");
  if (fstat(fileno(s->request_body_file), &st) != 0) rb_sys_fail_str(path);

  setopt_or_raise(s->easy, CURLOPT_UPLOAD, 1L);
  setopt_or_raise(s->easy, CURLOPT_READFUNCTION, file_read_cb);
  setopt_or_raise(s->easy, CURLOPT_READDATA, s->request_body_file);
  setopt_or_raise(s->easy, CURLOPT_INFILESIZE_LARGE, (curl_off_t)st.st_size);
}

static void set_request_body(struct patron_session *s, VALUE stringable_or_file) {
  if (rb_respond_to(stringable_or_file, id_to_path)) {
    VALUE path = rb_funcallv(stringable_or_file, id_to_path, 0, NULL);
    set_request_body_from_file(s, rb_obj_as_string(path));
  } else {
    VALUE data = rb_obj_as_string(stringable_or_file);
    SESSION_WRITE(s, upload_data, data);
    setopt_or_raise(s->easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)RSTRING_LEN(data));
    setopt_or_raise(s->easy, CURLOPT_POSTFIELDS, RSTRING_PTR(data));
  }
}

static long seconds_to_milliseconds(VALUE seconds) {
  return (long)(NUM2DBL(seconds) * 1000.0);
}

static long lookup_version(VALUE table, VALUE requested, VALUE error_class, const char *what) {
  VALUE key = rb_obj_as_string(requested);
  VALUE found = rb_hash_lookup2(table, key, Qundef);

  if (found == Qundef) rb_raise(error_class, "Unsupported %s: %"PRIsVALUE, what, key);
  return NUM2LONG(found);
}

static void set_string_option(struct patron_session *s, CURLoption option, VALUE value, int is_path) {
  VALUE str = is_path ? rb_funcallv(value, id_to_s, 0, NULL) : rb_obj_as_string(value);
  if (is_path) FilePathValue(str);
  setopt_or_raise(s->easy, option, StringValueCStr(str));
}

static void set_options_from_request(struct patron_session *s, VALUE request) {
  VALUE self = s->self;
  CURL *easy;
  VALUE action_name, headers, url, value, upload_data, file_name;
  ID action;

  easy = curl_easy_duphandle(s->base);
  if (!easy) rb_memerror();
  /* Assigned before anything can raise so that cleanup() releases it. */
  s->easy = easy;

  value = request_attr(request, id_download_byte_limit);
  s->download_byte_limit = RTEST(value) ? NUM2OFFT(value) : 0;

  value = request_attr(request, id_progress_callback);
  SESSION_WRITE(s, progress_proc, rb_obj_is_proc(value) ? value : Qnil);

  headers = request_attr(request, id_headers);
  if (RTEST(headers)) {
    Check_Type(headers, T_HASH);
    rb_hash_foreach(headers, each_http_header, self);
  }

  if (RTEST(request_attr(request, id_force_ipv4))) {
    setopt_or_raise(easy, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_V4);
  }

  action_name = request_attr(request, id_action);
  action = SYM2ID(action_name);
  upload_data = request_attr(request, id_upload_data);
  file_name = request_attr(request, id_file_name);

  if (action == id_get) {
    setopt_or_raise(easy, CURLOPT_HTTPGET, 1L);
    if (RTEST(upload_data)) {
      set_request_body(s, upload_data);
      setopt_or_raise(easy, CURLOPT_CUSTOMREQUEST, "GET");
    }
    if (RTEST(file_name)) {
      s->download_file = open_file(file_name, "wb");
      SESSION_WRITE(s, body_buf, Qnil);
    }
  } else if (action == id_post || action == id_put || action == id_patch) {
    VALUE multipart = request_attr(request, id_multipart);
    const char *verb = action == id_post ? "POST" : action == id_put ? "PUT" : "PATCH";

    setopt_or_raise(easy, CURLOPT_CUSTOMREQUEST, verb);

    if (RTEST(multipart)) {
      if (RTEST(upload_data)) {
        Check_Type(upload_data, T_HASH);
        rb_hash_foreach(upload_data, each_mime_value, self);
      }
      if (RTEST(file_name)) {
        Check_Type(file_name, T_HASH);
        rb_hash_foreach(file_name, each_mime_file, self);
      }
      if (!s->mime) s->mime = curl_mime_init(easy);
      setopt_or_raise(easy, CURLOPT_MIMEPOST, s->mime);
    } else if (RTEST(upload_data)) {
      if (action == id_post) setopt_or_raise(easy, CURLOPT_POST, 1L);
      set_request_body(s, upload_data);
    } else if (RTEST(file_name)) {
      s->headers = curl_slist_append(s->headers, "Transfer-Encoding: chunked");
      set_request_body_from_file(s, rb_obj_as_string(file_name));
    } else {
      rb_raise(rb_eArgError, "Must provide either data or a filename when doing a PUT, POST or PATCH");
    }
  } else if (action == id_delete) {
    if (RTEST(upload_data)) {
      setopt_or_raise(easy, CURLOPT_POST, 1L);
      set_request_body(s, upload_data);
    }
    setopt_or_raise(easy, CURLOPT_CUSTOMREQUEST, "DELETE");
  } else if (action == id_head) {
    setopt_or_raise(easy, CURLOPT_NOBODY, 1L);
  } else {
    VALUE verb = request_attr(request, id_action_name);
    setopt_or_raise(easy, CURLOPT_CUSTOMREQUEST, StringValueCStr(verb));
  }

  setopt_or_raise(easy, CURLOPT_HTTPHEADER, s->headers);

  if (RTEST(request_attr(request, id_automatic_content_encoding))) {
    setopt_or_raise(easy, CURLOPT_ACCEPT_ENCODING, "");
  }

  url = request_attr(request, id_url);
  if (!RTEST(url)) rb_raise(rb_eArgError, "Must provide a URL");
  set_string_option(s, CURLOPT_URL, url, 0);

  value = request_attr(request, id_timeout);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_TIMEOUT_MS, seconds_to_milliseconds(value));

  value = request_attr(request, id_connect_timeout);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_CONNECTTIMEOUT_MS, seconds_to_milliseconds(value));

  value = request_attr(request, id_dns_cache_timeout);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_DNS_CACHE_TIMEOUT, NUM2LONG(value));

  value = request_attr(request, id_low_speed_time);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_LOW_SPEED_TIME, NUM2LONG(value));

  value = request_attr(request, id_low_speed_limit);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_LOW_SPEED_LIMIT, NUM2LONG(value));

  value = request_attr(request, id_max_redirects);
  if (RTEST(value)) {
    long redirects = NUM2LONG(value);
    setopt_or_raise(easy, CURLOPT_FOLLOWLOCATION, redirects == 0 ? 0L : 1L);
    setopt_or_raise(easy, CURLOPT_MAXREDIRS, redirects);
  }

  value = request_attr(request, id_proxy);
  if (RTEST(value)) set_string_option(s, CURLOPT_PROXY, value, 0);

  value = request_attr(request, id_proxy_type);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_PROXYTYPE, NUM2LONG(value));

  value = request_attr(request, id_credentials);
  if (RTEST(value)) {
    setopt_or_raise(easy, CURLOPT_HTTPAUTH, NUM2LONG(request_attr(request, id_auth_type)));
    set_string_option(s, CURLOPT_USERPWD, value, 0);
  }

  if (RTEST(request_attr(request, id_ignore_content_length))) {
    setopt_or_raise(easy, CURLOPT_IGNORE_CONTENT_LENGTH, 1L);
  }

  if (RTEST(request_attr(request, id_insecure))) {
    setopt_or_raise(easy, CURLOPT_SSL_VERIFYPEER, 0L);
    setopt_or_raise(easy, CURLOPT_SSL_VERIFYHOST, 0L);
  }

  value = request_attr(request, id_ssl_version);
  if (RTEST(value)) {
    setopt_or_raise(easy, CURLOPT_SSLVERSION, lookup_version(hSSLVersions, value, eUnsupportedSSLVersion, "SSL version"));
  }

  value = request_attr(request, id_http_version);
  if (RTEST(value)) {
    setopt_or_raise(easy, CURLOPT_HTTP_VERSION, lookup_version(hHTTPVersions, value, eUnsupportedHTTPVersion, "HTTP version"));
  }

  value = request_attr(request, id_ssl_cert);
  if (RTEST(value)) set_string_option(s, CURLOPT_SSLCERT, value, 1);

  value = request_attr(request, id_ssl_cert_type);
  if (RTEST(value)) set_string_option(s, CURLOPT_SSLCERTTYPE, value, 0);

  value = request_attr(request, id_ssl_key);
  if (RTEST(value)) set_string_option(s, CURLOPT_SSLKEY, value, 1);

  value = request_attr(request, id_ssl_key_password);
  if (RTEST(value)) set_string_option(s, CURLOPT_KEYPASSWD, value, 0);

  value = request_attr(request, id_cacert);
  if (RTEST(value)) set_string_option(s, CURLOPT_CAINFO, value, 1);

  value = request_attr(request, id_buffer_size);
  if (RTEST(value)) setopt_or_raise(easy, CURLOPT_BUFFERSIZE, NUM2LONG(value));
}

/*----------------------------------------------------------------------------*/
/* Response                                                                   */

static void set_timing(CURL *easy, VALUE timings, const char *key, CURLINFO info) {
  curl_off_t microseconds = 0;
  if (curl_easy_getinfo(easy, info, &microseconds) == CURLE_OK) {
    rb_hash_aset(timings, ID2SYM(rb_intern(key)), rb_float_new((double)microseconds / 1000000.0));
  }
}

/* libcurl's cumulative transfer marks in seconds since the request started:
 * namelookup <= connect <= appconnect <= pretransfer <= starttransfer <= total. */
static VALUE create_timings(CURL *easy) {
  VALUE timings = rb_hash_new();
  set_timing(easy, timings, "namelookup",    CURLINFO_NAMELOOKUP_TIME_T);
  set_timing(easy, timings, "connect",       CURLINFO_CONNECT_TIME_T);
  set_timing(easy, timings, "appconnect",    CURLINFO_APPCONNECT_TIME_T);
  set_timing(easy, timings, "pretransfer",   CURLINFO_PRETRANSFER_TIME_T);
  set_timing(easy, timings, "starttransfer", CURLINFO_STARTTRANSFER_TIME_T);
  set_timing(easy, timings, "redirect",      CURLINFO_REDIRECT_TIME_T);
  set_timing(easy, timings, "total",         CURLINFO_TOTAL_TIME_T);
  return timings;
}

static VALUE create_response(struct patron_session *s) {
  VALUE self = s->self;
  CURL *easy = s->easy;
  VALUE kwargs = rb_hash_new();
  char *effective_url = NULL;
  long code = 0;
  long redirect_count = 0;
  VALUE klass;

  curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &effective_url);
  curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &code);
  curl_easy_getinfo(easy, CURLINFO_REDIRECT_COUNT, &redirect_count);

  rb_hash_aset(kwargs, ID2SYM(id_url_kw), effective_url ? rb_usascii_str_new_cstr(effective_url) : Qnil);
  rb_hash_aset(kwargs, ID2SYM(id_status_kw), LONG2NUM(code));
  rb_hash_aset(kwargs, ID2SYM(id_redirect_count_kw), LONG2NUM(redirect_count));
  rb_hash_aset(kwargs, ID2SYM(id_header_data_kw), s->header_buf);
  rb_hash_aset(kwargs, ID2SYM(id_body_kw), s->body_buf);
  rb_hash_aset(kwargs, ID2SYM(id_default_charset_kw), rb_funcallv(self, id_default_response_charset, 0, NULL));
  rb_hash_aset(kwargs, ID2SYM(id_timings_kw), create_timings(easy));

  klass = rb_funcallv(self, id_response_class, 0, NULL);
  return rb_class_new_instance_kw(1, &kwargs, klass, RB_PASS_KEYWORDS);
}

/*----------------------------------------------------------------------------*/
/* Performing a request                                                       */

struct poll_context {
  CURLM *multi;
  CURLMcode rc;
};

static void *poll_without_gvl(void *ptr) {
  struct poll_context *ctx = ptr;
  ctx->rc = curl_multi_poll(ctx->multi, NULL, 0, POLL_TIMEOUT_MS, NULL);
  return NULL;
}

/* Runs without the GVL whenever Ruby needs this thread back (Thread#kill, Thread#raise,
 * signals, interpreter exit). Only wakes the poll; Ruby decides after it returns whether
 * there is an exception to raise. */
static void wakeup_poll(void *ptr) {
  struct patron_session *s = ptr;
  curl_multi_wakeup(s->multi);
}

static void drive_transfer(struct patron_session *s) {
  int running = 1;
  CURLMcode mc;

  mc = curl_multi_add_handle(s->multi, s->easy);
  if (mc != CURLM_OK) rb_raise(ePatronError, "%s", curl_multi_strerror(mc));

  while (running) {
    mc = curl_multi_perform(s->multi, &running);
    if (mc != CURLM_OK) rb_raise(ePatronError, "%s", curl_multi_strerror(mc));
    if (s->pending_tag || s->interrupt) break;
    if (!running) break;

    struct poll_context ctx = { s->multi, CURLM_OK };
    /* Pending Ruby interrupts are raised right here as rb_nogvl returns; the rb_ensure
     * around the request takes care of the half-finished transfer. */
    rb_nogvl(poll_without_gvl, &ctx, wakeup_poll, s, RB_NOGVL_UBF_ASYNC_SAFE);
    if (ctx.rc != CURLM_OK) rb_raise(ePatronError, "%s", curl_multi_strerror(ctx.rc));
    if (s->interrupt) break;
  }
}

static CURLcode transfer_result(struct patron_session *s) {
  CURLcode result = CURLE_OK;
  CURLMsg *msg;
  int remaining = 0;

  while ((msg = curl_multi_info_read(s->multi, &remaining))) {
    if (msg->msg == CURLMSG_DONE && msg->easy_handle == s->easy) result = msg->data.result;
  }
  return result;
}

struct perform_args {
  struct patron_session *s;
  VALUE request;
};

static VALUE perform(VALUE ptr) {
  struct perform_args *args = (struct perform_args *)ptr;
  struct patron_session *s = args->s;
  CURLcode result;

  s->interrupt = 0;
  s->pending_tag = 0;
  s->error_buf[0] = '\0';
  SESSION_WRITE(s, header_buf, rb_str_buf_new(HEADER_BUFFER_INITIAL_CAPACITY));
  SESSION_WRITE(s, body_buf, rb_str_buf_new(BODY_BUFFER_INITIAL_CAPACITY));

  set_options_from_request(s, args->request);
  drive_transfer(s);

  if (s->pending_tag) reraise_parked(s);

  if (s->interrupt == INTERRUPT_DOWNLOAD_OVERFLOW) {
    raise_curl_error(eDownloadLimitExceeded, CURLE_ABORTED_BY_CALLBACK, "Download byte limit exceeded");
  }
  if (s->interrupt) {
    raise_curl_error(eAborted, CURLE_ABORTED_BY_CALLBACK, "Request interrupted");
  }

  result = transfer_result(s);
  if (result != CURLE_OK) raise_curl_error(error_class_for(result), result, s->error_buf);

  /* Write the cookies accumulated in the share out to the jar, if one is configured */
  curl_easy_setopt(s->easy, CURLOPT_COOKIELIST, "FLUSH");

  return create_response(s);
}

/* Runs under rb_ensure after every request, whether it finished, raised or was interrupted. */
static VALUE cleanup(VALUE self) {
  struct patron_session *s = get_session(self);

  if (s->easy) {
    curl_multi_remove_handle(s->multi, s->easy);
    curl_easy_cleanup(s->easy);
    s->easy = NULL;
  }
  if (s->mime) {
    curl_mime_free(s->mime);
    s->mime = NULL;
  }
  if (s->headers) {
    curl_slist_free_all(s->headers);
    s->headers = NULL;
  }
  if (s->download_file) {
    fclose(s->download_file);
    s->download_file = NULL;
  }
  if (s->request_body_file) {
    fclose(s->request_body_file);
    s->request_body_file = NULL;
  }

  SESSION_WRITE(s, progress_proc, Qnil);
  SESSION_WRITE(s, upload_data, Qnil);
  SESSION_WRITE(s, header_buf, Qnil);
  SESSION_WRITE(s, body_buf, Qnil);
  s->download_byte_limit = 0;
  s->busy = 0;
  return Qnil;
}

/*
 * Performs the HTTP request described by +request+ and returns a Response built with
 * #response_class. Raises a Patron::Error subclass when libcurl reports a failure.
 *
 * @param request [Patron::Request]
 * @return [Patron::Response]
 */
static VALUE session_handle_request(VALUE self, VALUE request) {
  struct patron_session *s = get_session(self);
  struct perform_args args = { s, request };

  if (s->busy) {
    rb_raise(ePatronError, "This Session is already performing a request in another thread; use one Session per thread");
  }
  ensure_handles_for_this_process(s);
  s->busy = 1;
  return rb_ensure(perform, (VALUE)&args, cleanup, self);
}

/*
 * Aborts the request currently in flight on this Session, which then raises Patron::Aborted.
 * Safe to call from another thread.
 *
 * @return self
 */
static VALUE session_interrupt(VALUE self) {
  struct patron_session *s = get_session(self);

  s->interrupt = INTERRUPT_ABORT;
  if (s->multi) curl_multi_wakeup(s->multi);
  return self;
}

/*
 * Enables cookie handling: in memory when +path+ is empty, otherwise read from and written
 * back to the file at +path+.
 */
static VALUE session_set_cookie_file(VALUE self, VALUE path) {
  struct patron_session *s = get_session(self);
  const char *file_path = StringValueCStr(path);

  if (*file_path) setopt_or_raise(s->base, CURLOPT_COOKIEJAR, file_path);
  setopt_or_raise(s->base, CURLOPT_COOKIEFILE, file_path);
  return self;
}

/*
 * Sends libcurl's verbose output to +io+, or disables it when +io+ is nil.
 */
static VALUE session_set_debug_io(VALUE self, VALUE io) {
  struct patron_session *s = get_session(self);

  SESSION_WRITE(s, debug_io, io);
  setopt_or_raise(s->base, CURLOPT_VERBOSE, NIL_P(io) ? 0L : 1L);
  return self;
}

/*----------------------------------------------------------------------------*/
/* Init                                                                       */

static VALUE shareable_table(void) {
  return rb_hash_new();
}

static void table_entry(VALUE table, const char *name, long value) {
  rb_hash_aset(table, rb_interned_str_cstr(name), LONG2NUM(value));
}

void Init_session_ext(void) {
  /* Must precede the method definitions it applies to. There is no mutable global state:
   * every handle belongs to one Session, and libcurl's own globals are initialised once here. */
  rb_ext_ractor_safe(true);

  curl_global_init(CURL_GLOBAL_ALL);
  rb_require("patron/error");
  rb_require("patron/request");

#define DEFINE_ID(name) id_##name = rb_intern_const(#name);
  REQUEST_ATTRIBUTES(DEFINE_ID)
#undef DEFINE_ID
  id_to_path = rb_intern_const("to_path");
  id_to_s = rb_intern_const("to_s");
  id_response_class = rb_intern_const("response_class");
  id_default_response_charset = rb_intern_const("default_response_charset");
  id_get = rb_intern_const("get");
  id_post = rb_intern_const("post");
  id_put = rb_intern_const("put");
  id_patch = rb_intern_const("patch");
  id_delete = rb_intern_const("delete");
  id_head = rb_intern_const("head");
  id_ivar_curl_code = rb_intern_const("@curl_code");
  id_url_kw = rb_intern_const("url");
  id_status_kw = rb_intern_const("status");
  id_redirect_count_kw = rb_intern_const("redirect_count");
  id_header_data_kw = rb_intern_const("header_data");
  id_body_kw = rb_intern_const("body");
  id_default_charset_kw = rb_intern_const("default_charset");
  id_timings_kw = rb_intern_const("timings");

  mPatron = rb_define_module("Patron");

  /* These are Ruby-defined classes and tables, not immortal rb_define_class() ones,
   * so the GC has to know about the slots or compaction leaves them dangling */
  rb_global_variable(&cRequest);
  rb_global_variable(&hSSLVersions);
  rb_global_variable(&hHTTPVersions);
  rb_global_variable(&ePatronError);
  rb_global_variable(&eUnsupportedProtocol);
  rb_global_variable(&eUnsupportedSSLVersion);
  rb_global_variable(&eUnsupportedHTTPVersion);
  rb_global_variable(&eURLFormatError);
  rb_global_variable(&eHostResolutionError);
  rb_global_variable(&eConnectionFailed);
  rb_global_variable(&ePartialFileError);
  rb_global_variable(&eTimeoutError);
  rb_global_variable(&eTooManyRedirects);
  rb_global_variable(&eAborted);
  rb_global_variable(&eDownloadLimitExceeded);
  rb_global_variable(&eClientCertificateError);

  ePatronError = rb_const_get(mPatron, rb_intern("Error"));
  eUnsupportedProtocol = rb_const_get(mPatron, rb_intern("UnsupportedProtocol"));
  eUnsupportedSSLVersion = rb_const_get(mPatron, rb_intern("UnsupportedSSLVersion"));
  eUnsupportedHTTPVersion = rb_const_get(mPatron, rb_intern("UnsupportedHTTPVersion"));
  eURLFormatError = rb_const_get(mPatron, rb_intern("URLFormatError"));
  eHostResolutionError = rb_const_get(mPatron, rb_intern("HostResolutionError"));
  eConnectionFailed = rb_const_get(mPatron, rb_intern("ConnectionFailed"));
  ePartialFileError = rb_const_get(mPatron, rb_intern("PartialFileError"));
  eTimeoutError = rb_const_get(mPatron, rb_intern("TimeoutError"));
  eTooManyRedirects = rb_const_get(mPatron, rb_intern("TooManyRedirects"));
  eAborted = rb_const_get(mPatron, rb_intern("Aborted"));
  eDownloadLimitExceeded = rb_const_get(mPatron, rb_intern("DownloadLimitExceeded"));
  eClientCertificateError = rb_const_get(mPatron, rb_intern("ClientCertificateError"));

  rb_define_module_function(mPatron, "libcurl_version", libcurl_version, 0);
  rb_define_module_function(mPatron, "libcurl_version_exact", libcurl_version_exact, 0);
  rb_define_module_function(mPatron, "libcurl_features", libcurl_features, 0);

  cSession = rb_define_class_under(mPatron, "Session", rb_cObject);
  /* Defined in Ruby as a Data subclass; we only hang constants off it */
  cRequest = rb_path2class("Patron::Request");
  rb_define_alloc_func(cSession, session_alloc);

  /* escape/unescape are available on the class as well, for Patron::Util */
  rb_define_singleton_method(cSession, "escape", session_escape, 1);
  rb_define_method(cSession, "escape", session_escape, 1);
  rb_define_singleton_method(cSession, "unescape", session_unescape, 1);
  rb_define_method(cSession, "unescape", session_unescape, 1);
  rb_define_alias(cSession, "urlencode", "escape");
  rb_define_alias(cSession, "urldecode", "unescape");

  rb_define_private_method(cSession, "handle_request", session_handle_request, 1);
  rb_define_private_method(cSession, "set_cookie_file", session_set_cookie_file, 1);
  rb_define_private_method(cSession, "set_debug_io", session_set_debug_io, 1);
  rb_define_method(cSession, "interrupt", session_interrupt, 0);

  rb_define_const(cRequest, "AuthBasic", LONG2NUM(CURLAUTH_BASIC));
  rb_define_const(cRequest, "AuthDigest", LONG2NUM(CURLAUTH_DIGEST));
  rb_define_const(cRequest, "AuthAny", LONG2NUM(CURLAUTH_ANY));

  hSSLVersions = shareable_table();
  table_entry(hSSLVersions, "TLSv1", CURL_SSLVERSION_TLSv1);
  table_entry(hSSLVersions, "TLSv1_0", CURL_SSLVERSION_TLSv1_0);
  table_entry(hSSLVersions, "TLSv1_1", CURL_SSLVERSION_TLSv1_1);
  table_entry(hSSLVersions, "TLSv1_2", CURL_SSLVERSION_TLSv1_2);
  table_entry(hSSLVersions, "TLSv1_3", CURL_SSLVERSION_TLSv1_3);
  rb_define_const(cRequest, "SSL_VERSIONS", rb_ractor_make_shareable(hSSLVersions));

  hHTTPVersions = shareable_table();
  table_entry(hHTTPVersions, "None", CURL_HTTP_VERSION_NONE);
  table_entry(hHTTPVersions, "HTTPv1_0", CURL_HTTP_VERSION_1_0);
  table_entry(hHTTPVersions, "HTTPv1_1", CURL_HTTP_VERSION_1_1);
  table_entry(hHTTPVersions, "HTTPv2_0", CURL_HTTP_VERSION_2_0);
  table_entry(hHTTPVersions, "HTTPv2_TLS", CURL_HTTP_VERSION_2TLS);
  table_entry(hHTTPVersions, "HTTPv2_PRIOR", CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE);
  table_entry(hHTTPVersions, "HTTPv3", CURL_HTTP_VERSION_3);
#if LIBCURL_VERSION_NUM >= 0x075800
  table_entry(hHTTPVersions, "HTTPv3_ONLY", CURL_HTTP_VERSION_3ONLY);
#endif
  rb_define_const(cRequest, "HTTP_VERSIONS", rb_ractor_make_shareable(hHTTPVersions));

  mProxyType = rb_define_module_under(mPatron, "ProxyType");
  rb_define_const(mProxyType, "HTTP", LONG2NUM(CURLPROXY_HTTP));
  rb_define_const(mProxyType, "HTTP_1_0", LONG2NUM(CURLPROXY_HTTP_1_0));
  rb_define_const(mProxyType, "HTTPS", LONG2NUM(CURLPROXY_HTTPS));
  rb_define_const(mProxyType, "SOCKS4", LONG2NUM(CURLPROXY_SOCKS4));
  rb_define_const(mProxyType, "SOCKS5", LONG2NUM(CURLPROXY_SOCKS5));
  rb_define_const(mProxyType, "SOCKS4A", LONG2NUM(CURLPROXY_SOCKS4A));
  rb_define_const(mProxyType, "SOCKS5_HOSTNAME", LONG2NUM(CURLPROXY_SOCKS5_HOSTNAME));
}
