// -------------------------------------------------------------------
//
// Patron HTTP Client: Interface to libcurl
// Copyright (c) 2008 The Hive http://www.thehive.com/
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// -------------------------------------------------------------------
#include <ruby.h>
#include <curl/curl.h>
#include "membuffer.h"
#include "sglib.h"  // Simple Generic Library -> http://sglib.sourceforge.net/

static VALUE mPatron = Qnil;
static VALUE mProxyType = Qnil;
static VALUE cSession = Qnil;
static VALUE cRequest = Qnil;
static VALUE ePatronError = Qnil;
static VALUE eUnsupportedProtocol = Qnil;
static VALUE eURLFormatError = Qnil;
static VALUE eHostResolutionError = Qnil;
static VALUE eConnectionFailed = Qnil;
static VALUE ePartialFileError = Qnil;
static VALUE eTimeoutError = Qnil;
static VALUE eTooManyRedirects = Qnil;


struct curl_state {
  CURL* handle;
  char* upload_buf;
  FILE* download_file;
  FILE* upload_file;
  FILE* debug_file;
  char error_buf[CURL_ERROR_SIZE];
  struct curl_slist* headers;
  struct curl_httppost* post;
  struct curl_httppost* last;
  membuffer header_buffer;
  membuffer body_buffer;
  int interrupt;
};


//------------------------------------------------------------------------------
// Curl Callbacks
//

// Takes data streamed from libcurl and writes it to a Ruby string buffer.
static size_t session_write_handler(char* stream, size_t size, size_t nmemb, membuffer* buf) {
  int rc = membuffer_append(buf, stream, size * nmemb);

  // return 0 to signal that we could not append data to our buffer
  if (MB_OK != rc) { return 0; }

  // otherwise, return the number of bytes appended
  return size * nmemb;
}

static size_t session_read_handler(char* stream, size_t size, size_t nmemb, char **buffer) {
  size_t result = 0;

  if (buffer != NULL && *buffer != NULL) {
    size_t len = size * nmemb;
    char *s1 = strncpy(stream, *buffer, len);
    result = strlen(s1);
    *buffer += result;
  }

  return result;
}

// A non-zero return value from the progress handler will terminate the
// current request. We use this fact in order to interrupt any request when
// either the user calls the "interrupt" method on the session or when the Ruby
// interpreter is attempting to exit.
static int session_progress_handler(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow) {
  struct curl_state* state = (struct curl_state*) clientp;
  return state->interrupt;
}


//------------------------------------------------------------------------------
// List of active curl sessions
//

struct curl_state_list {
  struct curl_state       *state;
  struct curl_state_list  *next;
};

#define CS_LIST_COMPARATOR(p, _state_) (p->state == _state_)

static struct curl_state_list *cs_list = NULL;

static void cs_list_append( struct curl_state *state ) {
  assert(state != NULL);
  struct curl_state_list *item = ruby_xmalloc(sizeof(struct curl_state_list));
  item->state = state;
  item->next = NULL;

  SGLIB_LIST_ADD(struct curl_state_list, cs_list, item, next);
}

static void cs_list_remove( struct curl_state *state ) {
  assert(state != NULL);
  struct curl_state_list *item = NULL;

  SGLIB_LIST_FIND_MEMBER(struct curl_state_list, cs_list, state, CS_LIST_COMPARATOR, next, item);
  if (item) {
    SGLIB_LIST_DELETE(struct curl_state_list, cs_list, item, next);
    ruby_xfree(item);
  }
}

static void cs_list_interrupt(VALUE data) {
  struct curl_state_list *item = NULL;

  SGLIB_LIST_MAP_ON_ELEMENTS(struct curl_state_list, cs_list, item, next, {
    item->state->interrupt = 1;
  });
}


//------------------------------------------------------------------------------
// Object allocation
//

// Cleans up the Curl handle when the Session object is garbage collected.
void session_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);

  if (curl->debug_file) {
    fclose(curl->debug_file);
    curl->debug_file = NULL;
  }

  membuffer_destroy( &curl->header_buffer );
  membuffer_destroy( &curl->body_buffer );

  cs_list_remove(curl);

  free(curl);
}

// Allocates curl_state data needed for a new Session object.
VALUE session_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, session_free, curl);
  cs_list_append(curl);
  return obj;
}


//------------------------------------------------------------------------------
// Method implementations
//

// Returns the version of the embedded libcurl as a string.
VALUE libcurl_version(VALUE klass) {
  char* value = curl_version();
  return rb_str_new2(value);
}

// Initializes the libcurl handle on object initialization.
// NOTE: This must be called from Session#initialize.
VALUE session_ext_initialize(VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  state->handle = curl_easy_init();
  state->post   = NULL;
  state->last   = NULL;

  membuffer_init( &state->header_buffer );
  membuffer_init( &state->body_buffer );

  curl_easy_setopt(state->handle, CURLOPT_NOSIGNAL, 1);
  curl_easy_setopt(state->handle, CURLOPT_NOPROGRESS, 0);
  curl_easy_setopt(state->handle, CURLOPT_PROGRESSFUNCTION, &session_progress_handler);
  curl_easy_setopt(state->handle, CURLOPT_PROGRESSDATA, state);

  return self;
}

// URL escapes the provided string.
VALUE session_escape(VALUE self, VALUE value) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE string = StringValue(value);
  char* escaped = curl_easy_escape(state->handle,
                                   RSTRING_PTR(string),
                                   RSTRING_LEN(string));

  VALUE retval = rb_str_new2(escaped);
  curl_free(escaped);

  return retval;
}

// Unescapes the provided string.
VALUE session_unescape(VALUE self, VALUE value) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE string = StringValue(value);
  char* unescaped = curl_easy_unescape(state->handle,
                                       RSTRING_PTR(string),
                                       RSTRING_LEN(string),
                                       NULL);

  VALUE retval = rb_str_new2(unescaped);
  curl_free(unescaped);

  return retval;
}

// Callback used to iterate over the HTTP headers and store them in an slist.
static int each_http_header(VALUE header_key, VALUE header_value, VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE name = rb_obj_as_string(header_key);
  VALUE value = rb_obj_as_string(header_value);

  VALUE header_str = Qnil;
  header_str = rb_str_plus(name, rb_str_new2(": "));
  header_str = rb_str_plus(header_str, value);

  state->headers = curl_slist_append(state->headers, StringValuePtr(header_str));
  return 0;
}

static int formadd_values(VALUE data_key, VALUE data_value, VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE name = rb_obj_as_string(data_key);
  VALUE value = rb_obj_as_string(data_value);

  curl_formadd(&state->post, &state->last, CURLFORM_PTRNAME, RSTRING_PTR(name),
                CURLFORM_PTRCONTENTS, RSTRING_PTR(value), CURLFORM_END);
  return 0;
}

static int formadd_files(VALUE data_key, VALUE data_value, VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE name = rb_obj_as_string(data_key);
  VALUE value = rb_obj_as_string(data_value);

  curl_formadd(&state->post, &state->last, CURLFORM_PTRNAME, RSTRING_PTR(name),
                CURLFORM_FILE, RSTRING_PTR(value), CURLFORM_END);

  return 0;
}

static void set_chunked_encoding(struct curl_state *state) {
  state->headers = curl_slist_append(state->headers, "Transfer-Encoding: chunked");
}

static FILE* open_file(VALUE filename, char* perms) {
  FILE* handle = fopen(StringValuePtr(filename), perms);
  if (!handle) {
    rb_raise(rb_eArgError, "Unable to open specified file.");
  }

  return handle;
}

// Set the options on the Curl handle from a Request object. Takes each field
// in the Request object and uses it to set the appropriate option on the Curl
// handle.
static void set_options_from_request(VALUE self, VALUE request) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  CURL* curl = state->handle;

  VALUE headers = rb_iv_get(request, "@headers");
  if (!NIL_P(headers)) {
    if (rb_type(headers) != T_HASH) {
      rb_raise(rb_eArgError, "Headers must be passed in a hash.");
    }

    rb_hash_foreach(headers, each_http_header, self);
  }
  ID action = SYM2ID(rb_iv_get(request, "@action"));
  if (action == rb_intern("get")) {
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);

    VALUE download_file = rb_iv_get(request, "@file_name");
    if (!NIL_P(download_file)) {
      state->download_file = open_file(download_file, "w");
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, state->download_file);
    } else {
      state->download_file = NULL;
    }
  } else if (action == rb_intern("post") || action == rb_intern("put")) {
    VALUE data = rb_iv_get(request, "@upload_data");
    VALUE filename = rb_iv_get(request, "@file_name");
    VALUE multipart = rb_iv_get(request, "@multipart");

    if (!NIL_P(data) && NIL_P(multipart)) {
      state->upload_buf = StringValuePtr(data);
      int len = RSTRING_LEN(data);

      if (action == rb_intern("post")) {
        curl_easy_setopt(curl, CURLOPT_POST, 1);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, state->upload_buf);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, len);
      } else {
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1);
        curl_easy_setopt(curl, CURLOPT_READFUNCTION, &session_read_handler);
        curl_easy_setopt(curl, CURLOPT_READDATA, &state->upload_buf);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE, len);
      }
    } else if (!NIL_P(filename) && NIL_P(multipart)) {
      set_chunked_encoding(state);

      curl_easy_setopt(curl, CURLOPT_UPLOAD, 1);

      if (action == rb_intern("post")) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "POST");
      }

      state->upload_file = open_file(filename, "r");
      curl_easy_setopt(curl, CURLOPT_READDATA, state->upload_file);
    } else if (!NIL_P(multipart)) {
      if (action == rb_intern("post")) {
        if(!NIL_P(data) && !NIL_P(filename)) {
          if (rb_type(data) == T_HASH && rb_type(filename) == T_HASH) {
            rb_hash_foreach(data, formadd_values, self);
            rb_hash_foreach(filename, formadd_files, self);
        } else {   rb_raise(rb_eArgError, "Data and Filename must be passed in a hash.");}
        }
        curl_easy_setopt(curl, CURLOPT_HTTPPOST, state->post);

      } else {
         rb_raise(rb_eArgError, "Multipart PUT not supported");
      }

    } else {
      rb_raise(rb_eArgError, "Must provide either data or a filename when doing a PUT or POST");
    }
  } else if (action == rb_intern("head")) {
    curl_easy_setopt(curl, CURLOPT_NOBODY, 1);
  } else {
    VALUE action_name = rb_funcall(request, rb_intern("action_name"), 0);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, StringValuePtr(action_name));
  }

  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, state->headers);
  curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, state->error_buf);

  VALUE url = rb_iv_get(request, "@url");
  if (NIL_P(url)) {
    rb_raise(rb_eArgError, "Must provide a URL");
  }
  curl_easy_setopt(curl, CURLOPT_URL, StringValuePtr(url));

  VALUE timeout = rb_iv_get(request, "@timeout");
  if (!NIL_P(timeout)) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, FIX2INT(timeout));
  }

  timeout = rb_iv_get(request, "@connect_timeout");
  if (!NIL_P(timeout)) {
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, FIX2INT(timeout));
  }

  VALUE redirects = rb_iv_get(request, "@max_redirects");
  if (!NIL_P(redirects)) {
    int r = FIX2INT(redirects);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, r == 0 ? 0 : 1);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, r);
  }

  VALUE proxy = rb_iv_get(request, "@proxy");
  if (!NIL_P(proxy)) {
      curl_easy_setopt(curl, CURLOPT_PROXY, StringValuePtr(proxy));
  }

  VALUE proxy_type = rb_iv_get(request, "@proxy_type");
  if (!NIL_P(proxy_type)) {
    curl_easy_setopt(curl, CURLOPT_PROXYTYPE, FIX2INT(proxy_type));
  }

  VALUE credentials = rb_funcall(request, rb_intern("credentials"), 0);
  if (!NIL_P(credentials)) {
    curl_easy_setopt(curl, CURLOPT_HTTPAUTH, FIX2INT(rb_iv_get(request, "@auth_type")));
    curl_easy_setopt(curl, CURLOPT_USERPWD, StringValuePtr(credentials));
  }

  VALUE ignore_content_length = rb_iv_get(request, "@ignore_content_length");
  if (!NIL_P(ignore_content_length)) {
    curl_easy_setopt(curl, CURLOPT_IGNORE_CONTENT_LENGTH, 1);
  }

  VALUE insecure = rb_iv_get(request, "@insecure");
  if(!NIL_P(insecure)) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 1);
  }

  VALUE buffer_size = rb_iv_get(request, "@buffer_size");
  if (!NIL_P(buffer_size)) {
     curl_easy_setopt(curl, CURLOPT_BUFFERSIZE, FIX2INT(buffer_size));
  }

  if(state->debug_file) {
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1);
    curl_easy_setopt(curl, CURLOPT_STDERR, state->debug_file);
  }
}

// Use the info in a Curl handle to create a new Response object.
static VALUE create_response(VALUE self, CURL* curl, VALUE header_buffer, VALUE body_buffer) {
  char* effective_url = NULL;
  curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
  VALUE url = rb_str_new2(effective_url);

  long code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  VALUE status = INT2NUM(code);

  long count = 0;
  curl_easy_getinfo(curl, CURLINFO_REDIRECT_COUNT, &count);
  VALUE redirect_count = INT2NUM(count);

  VALUE default_charset = rb_iv_get(self, "@default_response_charset");

  VALUE args[6] = { url, status, redirect_count, header_buffer, body_buffer, default_charset };

  return rb_class_new_instance(6, args,
                               rb_const_get(mPatron, rb_intern("Response")));
}

// Raise an exception based on the Curl error code.
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

    default: error = ePatronError;
  }

  return error;
}

// Perform the actual HTTP request by calling libcurl.
static VALUE perform_request(VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  // clear any interrupt flags
  state->interrupt = 0;

  CURL* curl = state->handle;
  membuffer* header_buffer = &state->header_buffer;
  membuffer* body_buffer = &state->body_buffer;

  membuffer_clear(header_buffer);
  membuffer_clear(body_buffer);

  // headers
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &session_write_handler);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, header_buffer);

  // body
  if (!state->download_file) {
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &session_write_handler);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, body_buffer);
  }

#if defined(HAVE_TBR) && defined(USE_TBR)
  CURLcode ret = rb_thread_blocking_region(curl_easy_perform, curl, RUBY_UBF_IO, 0);
#else
  CURLcode ret = curl_easy_perform(curl);
#endif

  if (CURLE_OK == ret) {
    VALUE header_str = membuffer_to_rb_str(header_buffer);
    VALUE body_str = Qnil;
    if (!state->download_file) { body_str = membuffer_to_rb_str(body_buffer); }

    return create_response(self, curl, header_str, body_str);
  } else {
    rb_raise(select_error(ret), "%s", state->error_buf);
  }
}

// Cleanup after each request by resetting the Curl handle and deallocating all
// request related objects such as the header slist.
static VALUE cleanup(VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  curl_easy_reset(state->handle);

  if (state->headers) {
    curl_slist_free_all(state->headers);
    state->headers = NULL;
  }

  if (state->download_file) {
    fclose(state->download_file);
    state->download_file = NULL;
  }

  if (state->upload_file) {
    fclose(state->upload_file);
    state->upload_file = NULL;
  }

  state->upload_buf = NULL;

  return Qnil;
}

VALUE session_handle_request(VALUE self, VALUE request) {
  set_options_from_request(self, request);
  return rb_ensure(&perform_request, self, &cleanup, self);
}

VALUE enable_cookie_session(VALUE self, VALUE file) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);
  CURL* curl = state->handle;
  char* file_path = RSTRING_PTR(file);
  if (file_path != NULL && strlen(file_path) != 0) {
    curl_easy_setopt(curl, CURLOPT_COOKIEJAR, file_path);
  }
  curl_easy_setopt(curl, CURLOPT_COOKIEFILE, file_path);
  return Qnil;
}

VALUE set_debug_file(VALUE self, VALUE file) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);
  char* file_path = RSTRING_PTR(file);

  if(state->debug_file){
    fclose(state->debug_file);
    state->debug_file = NULL;
  }

  if(file_path != NULL && strlen(file_path) != 0) {
    state->debug_file = open_file(file, "w");
  } else {
    state->debug_file = stderr;
  }

  return Qnil;
}


//------------------------------------------------------------------------------
// Extension initialization
//

void Init_session_ext() {
  curl_global_init(CURL_GLOBAL_ALL);
  rb_require("patron/error");

  rb_set_end_proc(&cs_list_interrupt, NULL);

  mPatron = rb_define_module("Patron");

  ePatronError = rb_const_get(mPatron, rb_intern("Error"));

  eUnsupportedProtocol = rb_const_get(mPatron, rb_intern("UnsupportedProtocol"));
  eURLFormatError = rb_const_get(mPatron, rb_intern("URLFormatError"));
  eHostResolutionError = rb_const_get(mPatron, rb_intern("HostResolutionError"));
  eConnectionFailed = rb_const_get(mPatron, rb_intern("ConnectionFailed"));
  ePartialFileError = rb_const_get(mPatron, rb_intern("PartialFileError"));
  eTimeoutError = rb_const_get(mPatron, rb_intern("TimeoutError"));
  eTooManyRedirects = rb_const_get(mPatron, rb_intern("TooManyRedirects"));

  rb_define_module_function(mPatron, "libcurl_version", libcurl_version, 0);

  cSession = rb_define_class_under(mPatron, "Session", rb_cObject);
  cRequest = rb_define_class_under(mPatron, "Request", rb_cObject);
  rb_define_alloc_func(cSession, session_alloc);

  rb_define_method(cSession, "ext_initialize", session_ext_initialize, 0);
  rb_define_method(cSession, "escape",         session_escape,         1);
  rb_define_method(cSession, "unescape",       session_unescape,       1);
  rb_define_method(cSession, "handle_request", session_handle_request, 1);
  rb_define_method(cSession, "enable_cookie_session", enable_cookie_session, 1);
  rb_define_method(cSession, "set_debug_file", set_debug_file, 1);

  rb_define_const(cRequest, "AuthBasic",  INT2FIX(CURLAUTH_BASIC));
  rb_define_const(cRequest, "AuthDigest", INT2FIX(CURLAUTH_DIGEST));
  rb_define_const(cRequest, "AuthAny",    INT2FIX(CURLAUTH_ANY));

  mProxyType = rb_define_module_under(mPatron, "ProxyType");
  rb_define_const(mProxyType, "HTTP", INT2FIX(CURLPROXY_HTTP));
  rb_define_const(mProxyType, "HTTP_1_0", INT2FIX(CURLPROXY_HTTP_1_0));
  rb_define_const(mProxyType, "SOCKS4", INT2FIX(CURLPROXY_SOCKS4));
  rb_define_const(mProxyType, "SOCKS5", INT2FIX(CURLPROXY_SOCKS5));
  rb_define_const(mProxyType, "SOCKS4A", INT2FIX(CURLPROXY_SOCKS4A));
  rb_define_const(mProxyType, "SOCKS5_HOSTNAME", INT2FIX(CURLPROXY_SOCKS5_HOSTNAME));
}

