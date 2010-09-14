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

static VALUE mPatron = Qnil;
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
  char error_buf[CURL_ERROR_SIZE];
  struct curl_slist* headers;
};


//------------------------------------------------------------------------------
// Curl Callbacks
//

// Takes data streamed from libcurl and writes it to a Ruby string buffer.
static size_t session_write_handler(char* stream, size_t size, size_t nmemb, VALUE out) {
  rb_str_buf_cat(out, stream, size * nmemb);
  return size * nmemb;
}

static size_t session_read_handler(char* stream, size_t size, size_t nmemb, char **buffer) {
  size_t result = 0;

  if (buffer != NULL && *buffer != NULL) {
      int len = size * nmemb;
      char *s1 = strncpy(stream, *buffer, len);
      result = strlen(s1);
      *buffer += result;
  }

  return result;
}

//------------------------------------------------------------------------------
// Object allocation
//

// Cleans up the Curl handle when the Session object is garbage collected.
void session_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

// Allocates curl_state data needed for a new Session object.
VALUE session_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, session_free, curl);
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

    if (!NIL_P(data)) {
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
    } else if (!NIL_P(filename)) {
      set_chunked_encoding(state);

      curl_easy_setopt(curl, CURLOPT_UPLOAD, 1);

      if (action == rb_intern("post")) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "POST");
      }

      state->upload_file = open_file(filename, "r");
      curl_easy_setopt(curl, CURLOPT_READDATA, state->upload_file);
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

  VALUE credentials = rb_funcall(request, rb_intern("credentials"), 0);
  if (!NIL_P(credentials)) {
    curl_easy_setopt(curl, CURLOPT_HTTPAUTH, FIX2INT(rb_iv_get(request, "@auth_type")));
    curl_easy_setopt(curl, CURLOPT_USERPWD, StringValuePtr(credentials));
  }

  VALUE insecure = rb_iv_get(request, "@insecure");
  if(!NIL_P(insecure)) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 1);
  }
}

// Use the info in a Curl handle to create a new Response object.
static VALUE create_response(CURL* curl) {
  VALUE response = rb_class_new_instance(0, 0,
                      rb_const_get(mPatron, rb_intern("Response")));

  char* url = NULL;
  curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &url);
  rb_iv_set(response, "@url", rb_str_new2(url));

  long code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  rb_iv_set(response, "@status", INT2NUM(code));

  long count = 0;
  curl_easy_getinfo(curl, CURLINFO_REDIRECT_COUNT, &count);
  rb_iv_set(response, "@redirect_count", INT2NUM(count));

  return response;
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

  CURL* curl = state->handle;

  // headers
  VALUE header_buffer = rb_str_buf_new(32768);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &session_write_handler);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, header_buffer);

  // body
  VALUE body_buffer = Qnil;
  if (!state->download_file) {
    body_buffer = rb_str_buf_new(32768);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &session_write_handler);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, body_buffer);
  }

#if defined(HAVE_TBR) && defined(USE_TBR)
  CURLcode ret = rb_thread_blocking_region(curl_easy_perform, curl, RUBY_UBF_IO, 0);
#else
  CURLcode ret = curl_easy_perform(curl);
#endif

  if (CURLE_OK == ret) {
    VALUE response = create_response(curl);
    if (!NIL_P(body_buffer)) {
      rb_iv_set(response, "@body", body_buffer);
    }
    rb_funcall(response, rb_intern("parse_headers"), 1, header_buffer);
    return response;
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

//------------------------------------------------------------------------------
// Extension initialization
//

void Init_session_ext() {
  curl_global_init(CURL_GLOBAL_ALL);
  rb_require("patron/error");

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

  rb_define_const(cRequest, "AuthBasic",  INT2FIX(CURLAUTH_BASIC));
  rb_define_const(cRequest, "AuthDigest", INT2FIX(CURLAUTH_DIGEST));
  rb_define_const(cRequest, "AuthAny",    INT2FIX(CURLAUTH_ANY));
}
