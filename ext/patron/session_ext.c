#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cSession = Qnil;

struct curl_state {
  CURL* handle;
};


//------------------------------------------------------------------------------
// Callback support
//

// static size_t session_write_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
//   size_t result = size * nmemb;
//   rb_funcall(proc, rb_intern("call"), 1, rb_str_new(stream, result));
//   return result;
// }
// 
// static size_t session_read_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
//   size_t result = size * nmemb;
//   VALUE string = rb_funcall(proc, rb_intern("call"), 1, result);
//   size_t len = RSTRING(string)->len;
//   memcpy(stream, RSTRING(string)->ptr, len);
//   return len;
// }
 

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
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl->handle = curl_easy_init();

  return self;
}

VALUE session_escape(VALUE self, VALUE value) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  VALUE string = StringValue(value);
  char* escaped = curl_easy_escape(curl->handle,
                                   RSTRING(string)->ptr,
                                   RSTRING(string)->len);

  VALUE retval = rb_str_new2(escaped);
  curl_free(escaped);

  return retval;
}

VALUE session_unescape(VALUE self, VALUE value) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  VALUE string = StringValue(value);
  char* unescaped = curl_easy_unescape(curl->handle,
                                       RSTRING(string)->ptr,
                                       RSTRING(string)->len,
                                       NULL);

  VALUE retval = rb_str_new2(unescaped);
  curl_free(unescaped);

  return retval;
}

VALUE session_handle_request(VALUE self, VALUE request) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  VALUE url = rb_iv_get(request, "@url");
  curl_easy_setopt(curl->handle, CURLOPT_URL, RSTRING(url)->ptr);

  curl_easy_perform(curl->handle);

  return Qnil;
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
