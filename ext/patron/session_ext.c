#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cSession = Qnil;

struct curl_state {
  CURL* handle;
};


//------------------------------------------------------------------------------
// Callbacks
//

static size_t session_write_handler(char* stream, size_t size, size_t nmemb, VALUE out) {
  rb_str_buf_cat(out, stream, size * nmemb);
  return size * nmemb;
}

// static size_t session_read_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
//   size_t result = size * nmemb;
//   VALUE string = rb_funcall(proc, rb_intern("call"), 1, result);
//   size_t len = RSTRING(string)->len;
//   memcpy(stream, RSTRING(string)->ptr, len);
//   return len;
// }
 
static VALUE each_http_header(VALUE header, struct curl_slist **list) {
  VALUE name = rb_obj_as_string(rb_ary_entry(header, 0));
  VALUE value = rb_obj_as_string(rb_ary_entry(header, 1));

  VALUE header_str = Qnil;
  header_str = rb_str_plus(name, rb_str_new2(": "));
  header_str = rb_str_plus(header_str, value);

  *list = curl_slist_append(*list, StringValuePtr(header_str));
  return Qnil;
}

//------------------------------------------------------------------------------
// Object allocation
//

void session_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

VALUE session_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, session_free, curl);
  return obj;
}


//------------------------------------------------------------------------------
// Method implementations
//

VALUE libcurl_version(VALUE klass) {
  char* value = curl_version();
  return rb_str_new2(value);
}

VALUE session_ext_initialize(VALUE self) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  state->handle = curl_easy_init();

  return self;
}

VALUE session_escape(VALUE self, VALUE value) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE string = StringValue(value);
  char* escaped = curl_easy_escape(state->handle,
                                   RSTRING(string)->ptr,
                                   RSTRING(string)->len);

  VALUE retval = rb_str_new2(escaped);
  curl_free(escaped);

  return retval;
}

VALUE session_unescape(VALUE self, VALUE value) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  VALUE string = StringValue(value);
  char* unescaped = curl_easy_unescape(state->handle,
                                       RSTRING(string)->ptr,
                                       RSTRING(string)->len,
                                       NULL);

  VALUE retval = rb_str_new2(unescaped);
  curl_free(unescaped);

  return retval;
}

void set_options_from_request(CURL* curl, VALUE request) {
  curl_easy_reset(curl);

  ID action = SYM2ID(rb_iv_get(request, "@action"));
  if (action == rb_intern("get")) {
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);
  } else if (action == rb_intern("post")) {
    curl_easy_setopt(curl, CURLOPT_HTTPPOST, 1);
  } else if (action == rb_intern("put")) {
    curl_easy_setopt(curl, CURLOPT_UPLOAD, 1);
  } else if (action == rb_intern("delete")) {
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
  } else if (action == rb_intern("head")) {
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "HEAD");
  }

  VALUE url = rb_iv_get(request, "@url");
  if (NIL_P(url)) {
    rb_raise(rb_eArgError, "Must provide a URL");
  }
  curl_easy_setopt(curl, CURLOPT_URL, StringValuePtr(url));

  VALUE timeout = rb_iv_get(request, "@timeout");
  if (!NIL_P(timeout)) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, FIX2INT(timeout));
  }

  VALUE redirects = rb_iv_get(request, "@max_redirects");
  if (!NIL_P(redirects)) {
    int r = FIX2INT(redirects);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, r == 0 ? 0 : 1);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, r);
  }

  struct curl_slist* hdrs = NULL;
  VALUE headers = rb_iv_get(request, "@headers");
  if (!NIL_P(headers)) {
    if (rb_type(headers) != T_HASH) {
      rb_raise(rb_eArgError, "Headers must be passed in a hash.");
    }

    rb_iterate(rb_each, headers, each_http_header, (VALUE) &hdrs);
  }

  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
}

VALUE create_response(CURL* curl) {
  VALUE response = rb_class_new_instance(0, 0,
                      rb_const_get(mPatron, rb_intern("Response")));

  char* url = NULL;
  curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &url);
  rb_iv_set(response, "@url", rb_str_new2(url));

  long code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  rb_iv_set(response, "@status", INT2NUM(code));

  return response;
}

VALUE session_handle_request(VALUE self, VALUE request) {
  struct curl_state *state;
  Data_Get_Struct(self, struct curl_state, state);

  CURL* curl = state->handle;

  set_options_from_request(curl, request);

  VALUE body_buffer = rb_str_buf_new(32768);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, (curl_write_callback) &session_write_handler);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, body_buffer);

  CURLcode ret = curl_easy_perform(curl);
  if (CURLE_OK == ret) {
    VALUE response = create_response(curl);
    rb_iv_set(response, "@body", body_buffer);
    return response;
  } else {
    rb_raise(rb_eRuntimeError, "Curl failed");
  }
}

//------------------------------------------------------------------------------
// Extension initialization
//

void Init_session_ext() {
  curl_global_init(CURL_GLOBAL_NOTHING);

  mPatron = rb_define_module("Patron");

  rb_define_module_function(mPatron, "libcurl_version", libcurl_version, 0);

  cSession = rb_define_class_under(mPatron, "Session", rb_cObject);
  rb_define_alloc_func(cSession, session_alloc);

  rb_define_method(cSession, "ext_initialize", session_ext_initialize, 0);
  rb_define_method(cSession, "escape",         session_escape,         1);
  rb_define_method(cSession, "unescape",       session_unescape,       1);
  rb_define_method(cSession, "handle_request", session_handle_request, 1);
}
