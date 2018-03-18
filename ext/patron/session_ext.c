#include <ruby.h>
#if defined(USE_TBR) && defined(HAVE_THREAD_H)
#include <ruby/thread.h>
#endif
#include <sys/stat.h>
#include <curl/curl.h>
#include "membuffer.h"
#include "sglib.h"  /* Simple Generic Library -> http://sglib.sourceforge.net */

#define UNUSED_ARGUMENT(x) (void)x
#define INTERRUPT_ABORT 1
#define INTERRUPT_DOWNLOAD_OVERFLOW 2

static VALUE mPatron = Qnil;
static VALUE mProxyType = Qnil;
static VALUE cSession = Qnil;
static VALUE cRequest = Qnil;
static VALUE ePatronError = Qnil;
static VALUE eUnsupportedProtocol = Qnil;
static VALUE eUnsupportedSSLVersion = Qnil;
static VALUE eUnsupportedHTTPVersion = Qnil;
static VALUE eURLFormatError = Qnil;
static VALUE eHostResolutionError = Qnil;
static VALUE eConnectionFailed = Qnil;
static VALUE ePartialFileError = Qnil;
static VALUE eTimeoutError = Qnil;
static VALUE eTooManyRedirects = Qnil;
static VALUE eAborted = Qnil;

struct patron_curl_state {
  CURL* handle;
  char* upload_buf;
  FILE* download_file;
  FILE* debug_file;
  FILE* request_body_file;
  char error_buf[CURL_ERROR_SIZE];
  struct curl_slist* headers;
  struct curl_httppost* post;
  struct curl_httppost* last;
  membuffer header_buffer;
  membuffer body_buffer;
  size_t download_byte_limit;
  VALUE user_progress_blk;
  int interrupt;
  size_t dltotal;
  size_t dlnow;
  size_t ultotal;
  size_t ulnow;
};


/*----------------------------------------------------------------------------*/
/* Curl Callbacks                                                             */

/* Takes data streamed from libcurl and writes it to a Ruby string buffer. */
static size_t session_write_handler(char* stream, size_t size, size_t nmemb, membuffer* buf) {
  int rc = membuffer_append(buf, stream, size * nmemb);

  /* return 0 to signal that we could not append data to our buffer */
  if (MB_OK != rc) { return 0; }

  /* otherwise, return the number of bytes appended */
  return size * nmemb;
}

/* Used as WRITEFUNCTION for file downloads (required on Windows) */
static size_t file_write_handler(void* stream, size_t size, size_t nmemb, FILE* fp) {
  fwrite(stream, size, nmemb, fp);
  if (ferror(fp)) {
    return 0;
  } else {
    /* Just always OK the write */
    return size * nmemb;
  }
}

static int call_user_rb_progress_blk(void* vd_curl_state) {
  struct patron_curl_state* state = (struct patron_curl_state*)vd_curl_state;
  // Invoke the block with the array
  VALUE blk_result = rb_funcall(state->user_progress_blk,
    rb_intern("call"), 4,
    LONG2NUM(state->dltotal),
    LONG2NUM(state->dlnow),
    LONG2NUM(state->ultotal),
    LONG2NUM(state->ulnow));
  return 0;
}


/* A non-zero return value from the progress handler will terminate the current
 * request. We use this fact in order to interrupt any request when either the
 * user calls the "interrupt" method on the session or when the Ruby interpreter
 * is attempting to exit.
 */
static int session_progress_handler(void* clientp, size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
  struct patron_curl_state* state = (struct patron_curl_state*) clientp;
  state->dltotal = dltotal;
  state->dlnow = dlnow;
  state->ultotal = ultotal;
  state->ulnow = ulnow;

  // If a progress proc has been set, re-acquire the GIL and call it using
  // `call_user_rb_progress_blk`. TODO: use the retval of that proc
  // to permit premature abort
  if(RTEST(state->user_progress_blk)) {
    // Even though it is not documented, rb_thread_call_with_gvl is available even when
    // rb_thread_call_without_gvl is not. See https://bugs.ruby-lang.org/issues/5543#note-4
    // > rb_thread_call_with_gvl() is globally-visible (but not in headers)
    // > for 1.9.3: https://bugs.ruby-lang.org/issues/4328
    #if (defined(HAVE_TBR) || defined(HAVE_TCWOGVL)) && defined(USE_TBR)
        rb_thread_call_with_gvl((void *(*)(void *)) call_user_rb_progress_blk, (void*)state);
    #else
        call_user_rb_progress_blk((void*)state);
    #endif
  }

  // Set the interrupt if the download byte limit has been reached
  if(state->download_byte_limit != 0 && (dltotal > state->download_byte_limit)) {
    state->interrupt = INTERRUPT_DOWNLOAD_OVERFLOW;
  }

  // If the interrupt value is anything except 0, the perform() call
  // will be aborted by libCURL.
  // Note however that some older versions of libcurl have a bug which
  // makes the return value of this callback be ignored, and the request
  // will actually proceed undeterred.
  // See https://sourceforge.net/p/curl/bugs/1318/
  return state->interrupt;
}


/*----------------------------------------------------------------------------*/
/* List of active curl sessions                                               */

struct patron_curl_state_list {
  struct patron_curl_state       *state;
  struct patron_curl_state_list  *next;
};

#define CS_LIST_COMPARATOR(p, _state_) (p->state - _state_)

static struct patron_curl_state_list *cs_list = NULL;

static void cs_list_append( struct patron_curl_state *state ) {
  struct patron_curl_state_list *item = NULL;

  assert(state != NULL);
  item = ruby_xmalloc(sizeof(struct patron_curl_state_list));
  item->state = state;
  item->next = NULL;

  SGLIB_LIST_ADD(struct patron_curl_state_list, cs_list, item, next);
}

static void cs_list_remove(struct patron_curl_state *state) {
  struct patron_curl_state_list *item = NULL;

  assert(state != NULL);

  SGLIB_LIST_DELETE_IF_MEMBER(struct patron_curl_state_list, cs_list, state, CS_LIST_COMPARATOR, next, item);
  if (item) {
    ruby_xfree(item);
  }
}

static void cs_list_interrupt(VALUE data) {
  UNUSED_ARGUMENT(data);

  SGLIB_LIST_MAP_ON_ELEMENTS(struct patron_curl_state_list, cs_list, item, next, {
    item->state->interrupt = INTERRUPT_ABORT;
  });
}


/*----------------------------------------------------------------------------*/
/* Object allocation                                                          */

static void session_close_debug_file(struct patron_curl_state *curl) {
  if (curl->debug_file && stderr != curl->debug_file) {
    fclose(curl->debug_file);
  }
  curl->debug_file = NULL;
}

/* Cleans up the Curl handle when the Session object is garbage collected. */
void session_free(struct patron_curl_state *curl) {
  if (curl->handle) {
    curl_easy_cleanup(curl->handle);
    curl->handle = NULL;
  }

  session_close_debug_file(curl);

  membuffer_destroy( &curl->header_buffer );
  membuffer_destroy( &curl->body_buffer );

  cs_list_remove(curl);

  free(curl);
}

/* Allocates patron_curl_state data needed for a new Session object. */
VALUE session_alloc(VALUE klass) {
  struct patron_curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct patron_curl_state, NULL, session_free, curl);

  membuffer_init( &curl->header_buffer );
  membuffer_init( &curl->body_buffer );
  cs_list_append(curl);

  return obj;
}

/* Return the patron_curl_state from the ruby VALUE which is the Session instance. */
static struct patron_curl_state* get_patron_curl_state(VALUE self) {
  struct patron_curl_state* state;
  Data_Get_Struct(self, struct patron_curl_state, state);

  if (NULL == state->handle) {
    state->handle = curl_easy_init();
    curl_easy_setopt(state->handle, CURLOPT_NOSIGNAL, 1);
    curl_easy_setopt(state->handle, CURLOPT_NOPROGRESS, 0);
    #if LIBCURL_VERSION_NUM >= 0x072000
      /* this is libCURLv7.32.0 or later, supports CURLOPT_XFERINFOFUNCTION */
      curl_easy_setopt(state->handle, CURLOPT_XFERINFOFUNCTION, &session_progress_handler);
    #else
      curl_easy_setopt(state->handle, CURLOPT_PROGRESSFUNCTION, &session_progress_handler);
    #endif

    curl_easy_setopt(state->handle, CURLOPT_PROGRESSDATA, state);
  }

  return state;
}


/*----------------------------------------------------------------------------*/
/* Method implementations                                                     */

/*
* Returns the version of the embedded libcurl.
*
*  @return [String] libcurl version string
 */
static VALUE libcurl_version(VALUE klass) {
  char* value = curl_version();
  UNUSED_ARGUMENT(klass);
  return rb_str_new2(value);
}

/*
* Returns the version of the embedded libcurl.
*
*  @return [Array] an array of MAJOR, MINOR, PATCH integers
 */
static VALUE libcurl_version_exact(VALUE klass) {
  UNUSED_ARGUMENT(klass);
  VALUE cv_major = INT2FIX(LIBCURL_VERSION_MAJOR);
  VALUE cv_minor = INT2FIX(LIBCURL_VERSION_MINOR);
  VALUE cv_patch = INT2FIX(LIBCURL_VERSION_PATCH);
  VALUE version_arr = rb_ary_new3(3, cv_major, cv_minor, cv_patch);
  return version_arr;
}

/*
 * Escapes the provided string using libCURL URL escaping functions.
 *
 * @param [String] value plain string to URL-escape
*  @return [String] the escaped string
 */
static VALUE session_escape(VALUE self, VALUE value) {

  VALUE string = StringValue(value);
  char* escaped = NULL;
  VALUE retval = Qnil;

  struct patron_curl_state* state = curl_easy_init();
  escaped = curl_easy_escape(state->handle,
                             RSTRING_PTR(string),
                             (int) RSTRING_LEN(string));

  retval = rb_str_new2(escaped);
  curl_easy_cleanup(state);
  curl_free(escaped);

  return retval;
}

/*
 * Unescapes the provided string using libCURL URL escaping functions.
 *
 * @param [String] value URL-encoded String to unescape
*  @return [String] unescaped (decoded) string
 */
static VALUE session_unescape(VALUE self, VALUE value) {
  VALUE string = StringValue(value);
  char* unescaped = NULL;
  VALUE retval = Qnil;

  struct patron_curl_state* state = curl_easy_init();
  unescaped = curl_easy_unescape(state->handle,
                                 RSTRING_PTR(string),
                                 (int) RSTRING_LEN(string),
                                 NULL);

  retval = rb_str_new2(unescaped);
  curl_free(unescaped);
  curl_easy_cleanup(state);

  return retval;
}

/* Callback used to iterate over the HTTP headers and store them in an slist. */
static int each_http_header(VALUE header_key, VALUE header_value, VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  CURL* curl = state->handle;

  VALUE name = rb_obj_as_string(header_key);
  VALUE value = rb_obj_as_string(header_value);
  VALUE header_str = Qnil;

  // TODO: see how to combine this with automatic_content_encoding
  if (rb_str_cmp(name, rb_str_new2("Accept-Encoding")) == 0) {
    if (rb_funcall(value, rb_intern("include?"), 1, rb_str_new2("gzip"))) {
      #ifdef CURLOPT_ACCEPT_ENCODING
        curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "gzip");
      #elif defined CURLOPT_ENCODING
        curl_easy_setopt(curl, CURLOPT_ENCODING, "gzip");
      #else
        rb_raise(rb_eArgError,
                "The libcurl version installed doesn't support 'gzip'.");
      #endif
    }
  }

  header_str = rb_str_plus(name, rb_str_new2(": "));
  header_str = rb_str_plus(header_str, value);

  state->headers = curl_slist_append(state->headers, StringValuePtr(header_str));

  return 0;
}

static int formadd_values(VALUE data_key, VALUE data_value, VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  VALUE name = rb_obj_as_string(data_key);
  VALUE value = rb_obj_as_string(data_value);

  curl_formadd(&state->post, &state->last, CURLFORM_PTRNAME, RSTRING_PTR(name),
                CURLFORM_PTRCONTENTS, RSTRING_PTR(value), CURLFORM_END);

  return 0;
}

static int formadd_files(VALUE data_key, VALUE data_value, VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  VALUE name = rb_obj_as_string(data_key);
  VALUE value = rb_obj_as_string(data_value);

  curl_formadd(&state->post, &state->last, CURLFORM_PTRNAME, RSTRING_PTR(name),
                CURLFORM_FILE, RSTRING_PTR(value), CURLFORM_END);

  return 0;
}

// Set the given char pointer and it's length to be the CURL request body
static void set_curl_request_body(CURL* curl, char* buf, curl_off_t len) {
  curl_easy_setopt(curl, CURLOPT_POSTFIELDS, buf);
  #ifdef CURLOPT_POSTFIELDSIZE_LARGE
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, len);
  #else
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, len);
  #endif
}

static void set_chunked_encoding(struct patron_curl_state *state) {
  state->headers = curl_slist_append(state->headers, "Transfer-Encoding: chunked");
}

static FILE* open_file(VALUE filename, const char* perms) {
  FILE* handle = fopen(StringValuePtr(filename), perms);
  if (!handle) {
    rb_raise(rb_eArgError, "Unable to open specified file.");
  }

  return handle;
}

static void set_request_body_file(struct patron_curl_state* state, VALUE r_path_str) {
  CURL* curl = state->handle;

  state->request_body_file = open_file(r_path_str, "rb");
  curl_easy_setopt(curl, CURLOPT_UPLOAD, 1);
  curl_easy_setopt(curl, CURLOPT_READDATA, state->request_body_file);
  struct stat stat_info;
  fstat(fileno(state->request_body_file), &stat_info);
  #ifdef CURLOPT_INFILESIZE_LARGE
    curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, stat_info.st_size);
  #else
    curl_easy_setopt(curl, CURLOPT_INFILESIZE, stat_info.st_size);
  #endif
}

static void set_request_body(struct patron_curl_state* state, VALUE stringable_or_file) {
  CURL* curl = state->handle;
  if(rb_respond_to(stringable_or_file, rb_intern("to_path"))) {
    // Set up a file read callback (read the entire request body from a file).
    // Instead of using the Ruby file reads, use #to_path to obtain the
    // file path on the file system and open a file pointer to it
    VALUE r_path_str = rb_funcall(stringable_or_file, rb_intern("to_path"), 0);
    r_path_str = rb_funcall(r_path_str, rb_intern("to_s"), 0);
    set_request_body_file(state, r_path_str);
  } else {
    // Set the request body from a String
    VALUE data = rb_funcall(stringable_or_file, rb_intern("to_s"), 0);
    long len = RSTRING_LEN(data);
    state->upload_buf = StringValuePtr(data);
    set_curl_request_body(curl, state->upload_buf, len);
  }
}

/* Set the options on the Curl handle from a Request object. Takes each field
 * in the Request object and uses it to set the appropriate option on the Curl
 * handle.
 */
static void set_options_from_request(VALUE self, VALUE request) {
  struct patron_curl_state* state = get_patron_curl_state(self);
  CURL* curl = state->handle;

  ID    action                = Qnil;
  VALUE headers               = Qnil;
  VALUE url                   = Qnil;
  VALUE timeout               = Qnil;
  VALUE redirects             = Qnil;
  VALUE proxy                 = Qnil;
  VALUE proxy_type            = Qnil;
  VALUE credentials           = Qnil;
  VALUE ignore_content_length = Qnil;
  VALUE insecure              = Qnil;
  VALUE cacert                = Qnil;
  VALUE ssl_version           = Qnil;
  VALUE ssl_cert              = Qnil;
  VALUE ssl_cert_type         = Qnil;
  VALUE ssl_key_password      = Qnil;
  VALUE http_version          = Qnil;
  VALUE buffer_size           = Qnil;
  VALUE action_name           = rb_funcall(request, rb_intern("action"), 0);
  VALUE a_c_encoding          = rb_funcall(request, rb_intern("automatic_content_encoding"), 0);
  VALUE download_byte_limit   = rb_funcall(request, rb_intern("download_byte_limit"), 0);
  VALUE maybe_progress_proc   = rb_funcall(request, rb_intern("progress_callback"), 0);

  if (RTEST(download_byte_limit)) {
    state->download_byte_limit = FIX2INT(download_byte_limit);
  } else {
    state->download_byte_limit = 0;
  }

  if (rb_obj_is_proc(maybe_progress_proc)) {
    state->user_progress_blk = maybe_progress_proc;
  } else {
    state->user_progress_blk = Qnil;
  }

  headers = rb_funcall(request, rb_intern("headers"), 0);
  if (RTEST(headers)) {
    if (rb_type(headers) != T_HASH) {
      rb_raise(rb_eArgError, "Headers must be passed in a hash.");
    }
    rb_hash_foreach(headers, each_http_header, self);
  }

  action = SYM2ID(action_name);
  if(rb_funcall(request, rb_intern("force_ipv4"), 0)) {
    curl_easy_setopt(curl, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4);
  }
  if (action == rb_intern("get")) {
    VALUE data = rb_funcall(request, rb_intern("upload_data"), 0);
    VALUE download_file = rb_funcall(request, rb_intern("file_name"), 0);

    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);
    if (RTEST(data)) {
      set_request_body(state, data);
      curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "GET");
    }
    if (RTEST(download_file)) {
      // we need the WRITEDATA option for the file destination
      state->download_file = open_file(download_file, "wb");
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, state->download_file);
      // curl docs say that CURLOPT_WRITEFUNCTION must be set too
      // to avoid issues on Windows
      curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &file_write_handler);
    } else {
      state->download_file = NULL;
    }
  } else if (action == rb_intern("post") || action == rb_intern("put") || action == rb_intern("patch")) {
    VALUE data = rb_funcall(request, rb_intern("upload_data"), 0);
    VALUE filename = rb_funcall(request, rb_intern("file_name"), 0);
    VALUE multipart = rb_funcall(request, rb_intern("multipart"), 0);

    if (action == rb_intern("post")) {
      curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "POST");
    } else if (action == rb_intern("put")) {
      curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PUT");
    } else if (action == rb_intern("patch")) {
      curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PATCH");
    }

    if (RTEST(data) && !RTEST(multipart)) {
      if (action == rb_intern("post")) {
        curl_easy_setopt(curl, CURLOPT_POST, 1);
      }
      set_request_body(state, data);
    } else if (RTEST(filename) && !RTEST(multipart)) {
      set_chunked_encoding(state);
      set_request_body_file(state, filename);
    } else if (RTEST(multipart)) {
      if (action == rb_intern("post")) {
        if(RTEST(data) && RTEST(filename)) {
          if (rb_type(data) == T_HASH && rb_type(filename) == T_HASH) {
            rb_hash_foreach(data, formadd_values, self);
            rb_hash_foreach(filename, formadd_files, self);
          } else {
            rb_raise(rb_eArgError, "Data and Filename must be passed in a hash.");
          }
        }
        curl_easy_setopt(curl, CURLOPT_HTTPPOST, state->post);
      } else {
         rb_raise(rb_eArgError, "Multipart PUT not supported");
      }

    } else {
      rb_raise(rb_eArgError, "Must provide either data or a filename when doing a PUT or POST");
    }

  // support for data passed with a DELETE request (e.g.: used by elasticsearch)
  } else if (action == rb_intern("delete")) {
      VALUE data = rb_funcall(request, rb_intern("upload_data"), 0);
      if (RTEST(data)) {
        long len = RSTRING_LEN(data);
        state->upload_buf = StringValuePtr(data);
        curl_easy_setopt(curl, CURLOPT_POST, 1);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, state->upload_buf);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, len);
      }
      curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");

  } else if (action == rb_intern("head")) {
    curl_easy_setopt(curl, CURLOPT_NOBODY, 1);
  } else {
    VALUE action_name = rb_funcall(request, rb_intern("action_name"), 0);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, StringValuePtr(action_name));
  }

  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, state->headers);
  curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, state->error_buf);

  // Enable automatic content-encoding support via gzip/deflate if set in the request,
  // see https://curl.haxx.se/libcurl/c/CURLOPT_ACCEPT_ENCODING.html
  if(RTEST(a_c_encoding)) {
    #ifdef CURLOPT_ACCEPT_ENCODING
      curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    #elif defined CURLOPT_ENCODING
      curl_easy_setopt(curl, CURLOPT_ENCODING, "");
    #else
      rb_raise(rb_eArgError,
        "The libcurl version installed doesn't support automatic content negotiation");
    #endif
  }

  url = rb_funcall(request, rb_intern("url"), 0);
  if (!RTEST(url)) {
    rb_raise(rb_eArgError, "Must provide a URL");
  }
  curl_easy_setopt(curl, CURLOPT_URL, StringValuePtr(url));

#ifdef CURLPROTO_HTTP
  // Security: do not allow Curl to go looking on gopher/SMTP etc.
  // Must prevent situations like this:
  // https://hackerone.com/reports/115748
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#endif

  timeout = rb_funcall(request, rb_intern("timeout"), 0);
  if (RTEST(timeout)) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, FIX2INT(timeout));
  }

  timeout = rb_funcall(request, rb_intern("connect_timeout"), 0);
  if (RTEST(timeout)) {
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, FIX2INT(timeout));
  }

  timeout = rb_funcall(request, rb_intern("dns_cache_timeout"), 0);
  if (RTEST(timeout)) {
    curl_easy_setopt(curl, CURLOPT_DNS_CACHE_TIMEOUT, FIX2INT(timeout));
  }

  VALUE low_speed_time = rb_funcall(request, rb_intern("low_speed_time"), 0);
  if(RTEST(low_speed_time)) {
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, FIX2LONG(low_speed_time));
  }

  VALUE low_speed_limit_bytes_per_second = rb_funcall(request, rb_intern("low_speed_limit"), 0);
  if(RTEST(low_speed_limit_bytes_per_second)) {
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, FIX2LONG(low_speed_limit_bytes_per_second));
  }

  redirects = rb_funcall(request, rb_intern("max_redirects"), 0);
  if (RTEST(redirects)) {
    int r = FIX2INT(redirects);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, r == 0 ? 0 : 1);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, r);
  }

  proxy = rb_funcall(request, rb_intern("proxy"), 0);
  if (RTEST(proxy)) {
    curl_easy_setopt(curl, CURLOPT_PROXY, StringValuePtr(proxy));
  }

  proxy_type = rb_funcall(request, rb_intern("proxy_type"), 0);
  if (RTEST(proxy_type)) {
    curl_easy_setopt(curl, CURLOPT_PROXYTYPE, NUM2LONG(proxy_type));
  }

  credentials = rb_funcall(request, rb_intern("credentials"), 0);
  if (RTEST(credentials)) {
    VALUE auth_type = rb_funcall(request, rb_intern("auth_type"), 0);
    curl_easy_setopt(curl, CURLOPT_HTTPAUTH, NUM2LONG(auth_type));
    curl_easy_setopt(curl, CURLOPT_USERPWD, StringValuePtr(credentials));
  }

  ignore_content_length = rb_funcall(request, rb_intern("ignore_content_length"), 0);
  if (RTEST(ignore_content_length)) {
    curl_easy_setopt(curl, CURLOPT_IGNORE_CONTENT_LENGTH, 1);
  }

  insecure = rb_funcall(request, rb_intern("insecure"), 0);
  if(RTEST(insecure)) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0);
  }

  ssl_version = rb_funcall(request, rb_intern("ssl_version"), 0);
  if(RTEST(ssl_version)) {
    VALUE ssl_version_str = rb_funcall(ssl_version, rb_intern("to_s"), 0);
    char* version = StringValuePtr(ssl_version_str);

    if(strcmp(version, "SSLv2") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_SSLv2);
    } else if(strcmp(version, "SSLv3") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_SSLv3);
    } else if(strcmp(version, "TLSv1") == 0) {
          curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1);
    }
    #if LIBCURL_VERSION_NUM >= 0x072200
    /* this is libCURLv7.34.0 or later */
    else if(strcmp(version, "TLSv1_0") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_0); //libcurl v7.34.0+
    } else if(strcmp(version, "TLSv1_1") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_1); //libcurl v7.34.0+
    } else if(strcmp(version, "TLSv1_2") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2); //libcurl v7.34.0+
    }
    #endif
    #if LIBCURL_VERSION_NUM >= 0x073400
    /* this is libCURLv7.52.0 or later */
    else if(strcmp(version, "TLSv1_3") == 0) {
      curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_3); //libcurl v7.52.0+
    }
    #endif
    else {
      rb_raise(eUnsupportedSSLVersion, "Unsupported SSL version: %s", version);
    }
  }

  http_version = rb_funcall(request, rb_intern("http_version"), 0);
  if(RTEST(http_version)) {
    VALUE http_version_str = rb_funcall(http_version, rb_intern("to_s"), 0);
    char* version = StringValuePtr(http_version_str);
    if(strcmp(version, "None") == 0) {
      curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_NONE);
    } else if(strcmp(version, "HTTPv1_0") == 0) {
      curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_0);
    } else if(strcmp(version, "HTTPv1_1") == 0) {
          curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    }
    #if LIBCURL_VERSION_NUM >= 0x072100
    /* this is libCURLv7.33.0 or later */
    else if(strcmp(version, "HTTPv2_0") == 0) {
      curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2_0); //libcurl v7.33.0+
    }
    #endif
    #if LIBCURL_VERSION_NUM >= 0x072F00
    /* this is libCURLv7.47.0 or later */
    else if(strcmp(version, "HTTPv2_TLS") == 0) {
      curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS); //libcurl v7.47.0+
    }
    #endif
    #if LIBCURL_VERSION_NUM >= 0x073100
    /* this is libCURLv7.49.0 or later */
    else if(strcmp(version, "HTTPv2_PRIOR") == 0) {
      curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE); //libcurl v7.49.0+
    }
    #endif
    else {
      rb_raise(eUnsupportedHTTPVersion, "Unsupported HTTP version: %s", version);
    }
  }

  ssl_cert = rb_funcall(request, rb_intern("ssl_cert"), 0);
  if(RTEST(ssl_cert)) {
    curl_easy_setopt(curl, CURLOPT_SSLCERT, StringValuePtr(ssl_cert));
  }

  ssl_cert_type = rb_funcall(request, rb_intern("ssl_cert_type"), 0);
  if(RTEST(ssl_cert_type)) {
    curl_easy_setopt(curl, CURLOPT_SSLCERTTYPE, StringValuePtr(ssl_cert_type));
  }

  ssl_key_password = rb_funcall(request, rb_intern("ssl_key_password"), 0);
  if(RTEST(ssl_key_password)) {
    curl_easy_setopt(curl, CURLOPT_SSLKEYPASSWD, StringValuePtr(ssl_key_password));
  }

  cacert = rb_funcall(request, rb_intern("cacert"), 0);
  if(RTEST(cacert)) {
    curl_easy_setopt(curl, CURLOPT_CAINFO, StringValuePtr(cacert));
  }

  buffer_size = rb_funcall(request, rb_intern("buffer_size"), 0);
  if (RTEST(buffer_size)) {
     curl_easy_setopt(curl, CURLOPT_BUFFERSIZE, NUM2LONG(buffer_size));
  }

  if(state->debug_file) {
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1);
    curl_easy_setopt(curl, CURLOPT_STDERR, state->debug_file);
  }
}

/* Use the info in a Curl handle to create a new Response object. */
static VALUE create_response(VALUE self, CURL* curl, VALUE header_buffer, VALUE body_buffer) {
  VALUE args[6] = { Qnil, Qnil, Qnil, Qnil, Qnil, Qnil };
  char* effective_url = NULL;
  long code = 0;
  long count = 0;
  VALUE responseKlass = Qnil;

  curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
  args[0] = rb_str_new2(effective_url);

  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  args[1] = INT2NUM(code);

  curl_easy_getinfo(curl, CURLINFO_REDIRECT_COUNT, &count);
  args[2] = INT2NUM(count);

  args[3] = header_buffer;
  args[4] = body_buffer;
  args[5] = rb_funcall(self, rb_intern("default_response_charset"), 0);

  responseKlass = rb_funcall(self, rb_intern("response_class"), 0);
  return rb_class_new_instance(6, args, responseKlass);
}

/* Raise an exception based on the Curl error code. */
static VALUE select_error(CURLcode code) {
  VALUE error = Qnil;
  switch (code) {
    case CURLE_UNSUPPORTED_PROTOCOL:  error = eUnsupportedProtocol; break;
    case CURLE_URL_MALFORMAT:         error = eURLFormatError;      break;
    case CURLE_COULDNT_RESOLVE_HOST:  error = eHostResolutionError; break;
    case CURLE_COULDNT_CONNECT:       error = eConnectionFailed;    break;
    case CURLE_PARTIAL_FILE:          error = ePartialFileError;    break;
    case CURLE_OPERATION_TIMEDOUT:    error = eTimeoutError;        break;
    case CURLE_TOO_MANY_REDIRECTS:    error = eTooManyRedirects;    break;
    case CURLE_ABORTED_BY_CALLBACK:   error = eAborted;             break;
    default: error = ePatronError;
  }

  return error;
}


/* Uses as the unblocking function when the thread running Patron gets
   signaled. The important difference with session_interrupt is that we
   are not allowed to touch any Ruby structures while outside the GIL,
   but we _are_ permitted to touch our internal curl state struct
*/
void session_ubf_abort(void* patron_state) {
  struct patron_curl_state* state = (struct patron_curl_state*) patron_state;
  state->interrupt = INTERRUPT_ABORT;
}

/* Perform the actual HTTP request by calling libcurl. */
static VALUE perform_request(VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  CURL* curl = state->handle;
  membuffer* header_buffer = NULL;
  membuffer* body_buffer = NULL;
  CURLcode ret = 0;

  state->interrupt = 0;            /* clear the interrupt flag */

  header_buffer = &state->header_buffer;
  body_buffer = &state->body_buffer;

  membuffer_clear(header_buffer);
  membuffer_clear(body_buffer);

  /* headers */
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &session_write_handler);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, header_buffer);

  /* body */
  if (!state->download_file) {
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &session_write_handler);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, body_buffer);
  }

#if (defined(HAVE_TBR) || defined(HAVE_TCWOGVL)) && defined(USE_TBR)
  #if defined(HAVE_TCWOGVL)
    ret = (CURLcode) rb_thread_call_without_gvl(
            (void *(*)(void *)) curl_easy_perform, curl,
            session_ubf_abort, (void*)state
          );
  #else
    ret = (CURLcode) rb_thread_blocking_region(
            (rb_blocking_function_t*) curl_easy_perform, curl,
            session_ubf_abort, (void*)state
          );
  #endif
#else
  ret = curl_easy_perform(curl);
#endif

  if (CURLE_OK == ret) {
    VALUE header_str = membuffer_to_rb_str(header_buffer);
    VALUE body_str = Qnil;
    if (!state->download_file) { body_str = membuffer_to_rb_str(body_buffer); }

    curl_easy_setopt(curl, CURLOPT_COOKIELIST, "FLUSH"); // Flush cookies to the cookie jar

    return create_response(self, curl, header_str, body_str);
  } else {
    rb_raise(select_error(ret), "%s", state->error_buf);
  }
}

/* Cleanup after each request by resetting the Curl handle and deallocating
 * all request related objects such as the header slist.
 */
static VALUE cleanup(VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  curl_easy_reset(state->handle);

  if (state->headers) {
    curl_slist_free_all(state->headers);
    state->headers = NULL;
  }

  if (state->download_file) {
    fclose(state->download_file);
    state->download_file = NULL;
  }

  if (state->request_body_file) {
    fclose(state->request_body_file);
    state->request_body_file = NULL;
  }

  if (state->post) {
    curl_formfree(state->post);
    state->post = NULL;
    state->last = NULL;
  }

  state->upload_buf = NULL;

  return Qnil;
}

/*
 * Peform the actual HTTP request by calling libcurl. Each filed in the
 * +request+ object will be used to set the appropriate option on the libcurl
 * library. After the request completes, a Response object will be created and
 * returned.
 *
 * In the event of an error in the libcurl library, a Ruby exception will be
 * created and raised. The exception will return the libcurl error code and
 * error message.
 *
 * @param request[Patron::Request] the request to use when filling the CURL options
 * @return [Patron::Response] the result of calling `response_class` on the Session
 */
static VALUE session_handle_request(VALUE self, VALUE request) {
  set_options_from_request(self, request);
  return rb_ensure(&perform_request, self, &cleanup, self);
}

/*
 * FIXME: figure out how this method should be used at all given Session is not multithreaded.
 * FIXME: also: what is the difference with `interrupt()` and also relationship with `cleanup()`?
 * Reset the underlying cURL session. This effectively closes all open
 * connections and disables debug output. There is no need to call this method
 * manually after performing a request, since cleanup is performed automatically
 * but the method can be used from another thread
 * to abort a request currently in progress.
 *
 * @return self
 */
static VALUE session_reset(VALUE self) {
  struct patron_curl_state *state;
  Data_Get_Struct(self, struct patron_curl_state, state);

  if (NULL != state->handle) {
    cleanup(self);
    curl_easy_cleanup(state->handle);
    state->handle = NULL;
    session_close_debug_file(state);
  }

  return self;
}

/* Interrupt any currently executing request. This will cause the current
 * request to error and raise an exception.
 *
 * @return [void] This method always raises
 */
static VALUE session_interrupt(VALUE self) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  state->interrupt = INTERRUPT_ABORT;
  return self;
}

/*
 * Turn on cookie handling for this session, storing them in memory by
 * default or in +file+ if specified. The `file` must be readable and
 * writable. Calling multiple times will add more files.
 * FIXME: what does the empty string actually do here?
*
 * @param [String] file path to the existing cookie file, or nil to store in memory.
*  @return self
 */
static VALUE add_cookie_file(VALUE self, VALUE file) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  CURL* curl = state->handle;
  char* file_path = NULL;

  // FIXME: http://websystemsengineering.blogspot.nl/2013/03/curloptcookiefile-vs-curloptcookiejar.html
  file_path = RSTRING_PTR(file);
  if (file_path != NULL && strlen(file_path) != 0) {
    curl_easy_setopt(curl, CURLOPT_COOKIEJAR, file_path);
  }
  curl_easy_setopt(curl, CURLOPT_COOKIEFILE, file_path);

  return self;
}

/*
 * Enable debug output to stderr or to specified +file+.
 *
 * @param [String, nil] file path to the debug file, or nil to write to STDERR
*  @return self
 */
static VALUE set_debug_file(VALUE self, VALUE file) {
  struct patron_curl_state *state = get_patron_curl_state(self);
  char* file_path = RSTRING_PTR(file);

  session_close_debug_file(state);

  if(file_path != NULL && strlen(file_path) != 0) {
    state->debug_file = open_file(file, "wb");
  } else {
    state->debug_file = stderr;
  }

  return self;
}


/*----------------------------------------------------------------------------*/
/* Extension initialization                                                   */

void Init_session_ext() {
  curl_global_init(CURL_GLOBAL_ALL);
  rb_require("patron/error");

  rb_set_end_proc(&cs_list_interrupt, Qnil);

  mPatron = rb_define_module("Patron");

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

  rb_define_module_function(mPatron, "libcurl_version",       libcurl_version, 0);
  rb_define_module_function(mPatron, "libcurl_version_exact", libcurl_version_exact, 0);

  cSession = rb_define_class_under(mPatron, "Session", rb_cObject);
  cRequest = rb_define_class_under(mPatron, "Request", rb_cObject);
  rb_define_alloc_func(cSession, session_alloc);

  // Make "escape" available both as a class method and as an instance method,
  // to make it usable to the Util module which does not have access to
  // the Session object internally
  rb_define_singleton_method(cSession, "escape",   session_escape,         1);
  rb_define_method(cSession, "escape",         session_escape,         1);
  rb_define_singleton_method(cSession, "unescape",   session_unescape,         1);
  rb_define_method(cSession, "unescape",       session_unescape,       1);

  rb_define_method(cSession, "handle_request", session_handle_request, 1);
  rb_define_method(cSession, "reset",          session_reset,          0);
  rb_define_method(cSession, "interrupt",      session_interrupt,      0);
  rb_define_method(cSession, "add_cookie_file", add_cookie_file, 1);
  rb_define_method(cSession, "set_debug_file", set_debug_file, 1);
  rb_define_alias(cSession, "urlencode", "escape");
  rb_define_alias(cSession, "urldecode", "unescape");

  rb_define_const(cRequest, "AuthBasic",  LONG2NUM(CURLAUTH_BASIC));
  rb_define_const(cRequest, "AuthDigest", LONG2NUM(CURLAUTH_DIGEST));
  rb_define_const(cRequest, "AuthAny",    LONG2NUM(CURLAUTH_ANY));

  mProxyType = rb_define_module_under(mPatron, "ProxyType");
  rb_define_const(mProxyType, "HTTP", LONG2NUM(CURLPROXY_HTTP));
  rb_define_const(mProxyType, "HTTP_1_0", LONG2NUM(CURLPROXY_HTTP_1_0));
  rb_define_const(mProxyType, "SOCKS4", LONG2NUM(CURLPROXY_SOCKS4));
  rb_define_const(mProxyType, "SOCKS5", LONG2NUM(CURLPROXY_SOCKS5));
  rb_define_const(mProxyType, "SOCKS4A", LONG2NUM(CURLPROXY_SOCKS4A));
  rb_define_const(mProxyType, "SOCKS5_HOSTNAME", LONG2NUM(CURLPROXY_SOCKS5_HOSTNAME));
}
