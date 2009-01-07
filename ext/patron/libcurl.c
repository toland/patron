#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cLibcurl = Qnil;

struct curl_state {
  CURL* handle;
};

void Init_libcurl();

void libcurl_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

VALUE libcurl_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, libcurl_free, curl);
  return obj;
}

VALUE libcurl_initialize(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl->handle = curl_easy_init();

  return self;
}

VALUE libcurl_setopt(VALUE self, VALUE option, VALUE parameter) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl_easy_setopt(curl->handle, FIX2INT(option), RSTRING(parameter)->ptr);

  return Qnil;
}

VALUE libcurl_getinfo(VALUE self, VALUE info) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  char* value = NULL;
  curl_easy_getinfo(curl->handle, FIX2INT(info), &value);

  return rb_str_new2(value);
}

void Init_libcurl() {
  curl_global_init(CURL_GLOBAL_NOTHING);

  mPatron = rb_define_module("Patron");
  cLibcurl = rb_define_class_under(mPatron, "Libcurl", rb_cObject);

  rb_define_const(cLibcurl, "OPT_URL", INT2FIX(CURLOPT_URL));

  rb_define_const(cLibcurl, "INFO_URL", INT2FIX(CURLINFO_EFFECTIVE_URL));

  rb_define_alloc_func(cLibcurl, libcurl_alloc);

  rb_define_method(cLibcurl, "initialize", libcurl_initialize, 0);
  rb_define_method(cLibcurl, "setopt", libcurl_setopt, 2);
  rb_define_method(cLibcurl, "getinfo", libcurl_getinfo, 1);
}
