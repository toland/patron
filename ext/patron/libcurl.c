#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cLibcurl = Qnil;

struct curl_state {
  CURL* handle;
};

void Init_libcurl();

static size_t libcurl_block_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
  size_t result = size * nmemb;
  rb_funcall(proc, rb_intern("call"), 1, rb_str_new(stream, result));
  return result;
}

void libcurl_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

VALUE libcurl_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, libcurl_free, curl);
  return obj;
}

VALUE libcurl_version(VALUE klass) {
  char* value = curl_version();
  return rb_str_new2(value);
}

VALUE libcurl_initialize(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl->handle = curl_easy_init();

  return self;
}

VALUE libcurl_escape(VALUE self, VALUE value) {
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

VALUE libcurl_unescape(VALUE self, VALUE value) {
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

VALUE libcurl_setopt(VALUE self, VALUE optval, VALUE parameter) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  int option = FIX2INT(optval);
  switch (option) {
    case CURLOPT_WRITEFUNCTION:
      curl_easy_setopt(curl->handle, CURLOPT_WRITEFUNCTION, &libcurl_block_shim);
      curl_easy_setopt(curl->handle, CURLOPT_WRITEDATA, parameter);
      break;

    default:
      curl_easy_setopt(curl->handle, option, RSTRING(parameter)->ptr);
  }

  return Qnil;
}

VALUE libcurl_getinfo(VALUE self, VALUE info) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  char* value = NULL;
  curl_easy_getinfo(curl->handle, FIX2INT(info), &value);

  return rb_str_new2(value);
}

VALUE libcurl_perform(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl_easy_perform(curl->handle);

  return Qnil;
}

void Init_libcurl() {
  curl_global_init(CURL_GLOBAL_NOTHING);

  mPatron = rb_define_module("Patron");
  cLibcurl = rb_define_class_under(mPatron, "Libcurl", rb_cObject);

  rb_define_const(cLibcurl, "OPT_URL", INT2FIX(CURLOPT_URL));
  rb_define_const(cLibcurl, "OPT_HTTPGET", INT2FIX(CURLOPT_HTTPGET));
  rb_define_const(cLibcurl, "OPT_WRITE_HANDLER", INT2FIX(CURLOPT_WRITEFUNCTION));

  rb_define_const(cLibcurl, "INFO_URL", INT2FIX(CURLINFO_EFFECTIVE_URL));

  rb_define_alloc_func(cLibcurl, libcurl_alloc);

  rb_define_singleton_method(cLibcurl, "version", libcurl_version, 0);

  rb_define_method(cLibcurl, "initialize",  libcurl_initialize, 0);
  rb_define_method(cLibcurl, "escape",      libcurl_escape,     1);
  rb_define_method(cLibcurl, "unescape",    libcurl_unescape,   1);
  rb_define_method(cLibcurl, "setopt",      libcurl_setopt,     2);
  rb_define_method(cLibcurl, "getinfo",     libcurl_getinfo,    1);
  rb_define_method(cLibcurl, "perform",     libcurl_perform,    0);
}
