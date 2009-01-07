#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cLibcurl = Qnil;
static VALUE mCurlOpts = Qnil;
static VALUE mCurlInfo = Qnil;

struct curl_state {
  CURL* handle;
};


//------------------------------------------------------------------------------
// Callback support
//

static size_t libcurl_write_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
  size_t result = size * nmemb;
  rb_funcall(proc, rb_intern("call"), 1, rb_str_new(stream, result));
  return result;
}

static size_t libcurl_read_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
  size_t result = size * nmemb;
  VALUE string = rb_funcall(proc, rb_intern("call"), 1, result);
  size_t len = RSTRING(string)->len;
  memcpy(stream, RSTRING(string)->ptr, len);
  return len;
}


//------------------------------------------------------------------------------
// Object allocation
//

void libcurl_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

VALUE libcurl_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, libcurl_free, curl);
  return obj;
}


//------------------------------------------------------------------------------
// Method implementations
//

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
    case CURLOPT_READFUNCTION:
      curl_easy_setopt(curl, CURLOPT_READFUNCTION, &libcurl_read_shim);
      curl_easy_setopt(curl, CURLOPT_READDATA, parameter);
      break;

    case CURLOPT_WRITEFUNCTION:
      curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &libcurl_write_shim);
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, parameter);
      break;

    case CURLOPT_HEADERFUNCTION:
      curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &libcurl_write_shim);
      curl_easy_setopt(curl, CURLOPT_HEADERDATA, parameter);
      break;

    default:
      switch (TYPE(parameter)) {
        case T_STRING:
          curl_easy_setopt(curl->handle, option, RSTRING(parameter)->ptr);
          break;

        case T_FIXNUM:
          curl_easy_setopt(curl->handle, option, FIX2INT(parameter));
          break;

        default:
          rb_raise(rb_eArgError, "Invalid option flag or value");
      }
  }

  return Qnil;
}

VALUE libcurl_getinfo(VALUE self, VALUE infoval) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  int info = FIX2INT(infoval);
  switch (info) {
    // returns string
    case CURLINFO_EFFECTIVE_URL:
    case CURLINFO_CONTENT_TYPE:
    case CURLINFO_FTP_ENTRY_PATH: {
      char* value = NULL;
      curl_easy_getinfo(curl->handle, info, &value);
      return rb_str_new2(value);
    }

    // returns long
    case CURLINFO_RESPONSE_CODE:
    case CURLINFO_HTTP_CONNECTCODE:
    case CURLINFO_FILETIME:
    case CURLINFO_REDIRECT_COUNT:
    case CURLINFO_HEADER_SIZE:
    case CURLINFO_REQUEST_SIZE:
    case CURLINFO_SSL_VERIFYRESULT:
    case CURLINFO_HTTPAUTH_AVAIL:
    case CURLINFO_PROXYAUTH_AVAIL:
    case CURLINFO_OS_ERRNO:
    case CURLINFO_NUM_CONNECTS: {
      long value = 0;
      curl_easy_getinfo(curl->handle, info, &value);
      return INT2FIX(value);
    }

    // returns double
    case CURLINFO_TOTAL_TIME:
    case CURLINFO_NAMELOOKUP_TIME:
    case CURLINFO_CONNECT_TIME:
    case CURLINFO_PRETRANSFER_TIME:
    case CURLINFO_STARTTRANSFER_TIME:
    case CURLINFO_REDIRECT_TIME:
    case CURLINFO_SIZE_UPLOAD:
    case CURLINFO_SIZE_DOWNLOAD:
    case CURLINFO_SPEED_DOWNLOAD:
    case CURLINFO_SPEED_UPLOAD:
    case CURLINFO_CONTENT_LENGTH_DOWNLOAD:
    case CURLINFO_CONTENT_LENGTH_UPLOAD: {
      double value = 0.0;
      curl_easy_getinfo(curl->handle, info, &value);
      return rb_float_new(value);
    }

    default:
      rb_raise(rb_eArgError, "Invalid info selector");
  }
}

VALUE libcurl_perform(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl_easy_perform(curl->handle);

  return Qnil;
}


//------------------------------------------------------------------------------
// Extension initialization
//

void Init_libcurl() {
  curl_global_init(CURL_GLOBAL_NOTHING);

  mPatron = rb_define_module("Patron");

  // Curl option constants
  mCurlOpts = rb_define_module_under(mPatron, "CurlOpts");

  rb_define_const(mCurlOpts, "URL", INT2FIX(CURLOPT_URL));
  rb_define_const(mCurlOpts, "HTTPGET", INT2FIX(CURLOPT_HTTPGET));

  rb_define_const(mCurlOpts, "READ_HANDLER", INT2FIX(CURLOPT_READFUNCTION));
  rb_define_const(mCurlOpts, "WRITE_HANDLER", INT2FIX(CURLOPT_WRITEFUNCTION));
  rb_define_const(mCurlOpts, "HEADER_HANDLER", INT2FIX(CURLOPT_HEADERFUNCTION));


  // Curl info constants
  mCurlInfo = rb_define_module_under(mPatron, "CurlInfo");

  rb_define_const(mCurlInfo, "EFFECTIVE_URL",           INT2FIX(CURLINFO_EFFECTIVE_URL));
  rb_define_const(mCurlInfo, "RESPONSE_CODE",           INT2FIX(CURLINFO_RESPONSE_CODE));
  rb_define_const(mCurlInfo, "HTTP_CONNECTCODE",        INT2FIX(CURLINFO_HTTP_CONNECTCODE));
  rb_define_const(mCurlInfo, "FILETIME",                INT2FIX(CURLINFO_FILETIME));
  rb_define_const(mCurlInfo, "TOTAL_TIME",              INT2FIX(CURLINFO_TOTAL_TIME));
  rb_define_const(mCurlInfo, "NAMELOOKUP_TIME",         INT2FIX(CURLINFO_NAMELOOKUP_TIME));
  rb_define_const(mCurlInfo, "CONNECT_TIME",            INT2FIX(CURLINFO_CONNECT_TIME));
  rb_define_const(mCurlInfo, "PRETRANSFER_TIME",        INT2FIX(CURLINFO_PRETRANSFER_TIME));
  rb_define_const(mCurlInfo, "STARTTRANSFER_TIME",      INT2FIX(CURLINFO_STARTTRANSFER_TIME));
  rb_define_const(mCurlInfo, "REDIRECT_TIME",           INT2FIX(CURLINFO_REDIRECT_TIME));
  rb_define_const(mCurlInfo, "REDIRECT_COUNT",          INT2FIX(CURLINFO_REDIRECT_COUNT));
  rb_define_const(mCurlInfo, "SIZE_UPLOAD",             INT2FIX(CURLINFO_SIZE_UPLOAD));
  rb_define_const(mCurlInfo, "SIZE_DOWNLOAD",           INT2FIX(CURLINFO_SIZE_DOWNLOAD));
  rb_define_const(mCurlInfo, "SPEED_DOWNLOAD",          INT2FIX(CURLINFO_SPEED_DOWNLOAD));
  rb_define_const(mCurlInfo, "SPEED_UPLOAD",            INT2FIX(CURLINFO_SPEED_UPLOAD));
  rb_define_const(mCurlInfo, "HEADER_SIZE",             INT2FIX(CURLINFO_HEADER_SIZE));
  rb_define_const(mCurlInfo, "REQUEST_SIZE",            INT2FIX(CURLINFO_REQUEST_SIZE));
  rb_define_const(mCurlInfo, "SSL_VERIFYRESULT",        INT2FIX(CURLINFO_SSL_VERIFYRESULT));
  rb_define_const(mCurlInfo, "SSL_ENGINES",             INT2FIX(CURLINFO_SSL_ENGINES));
  rb_define_const(mCurlInfo, "CONTENT_LENGTH_DOWNLOAD", INT2FIX(CURLINFO_CONTENT_LENGTH_DOWNLOAD));
  rb_define_const(mCurlInfo, "CONTENT_LENGTH_UPLOAD",   INT2FIX(CURLINFO_CONTENT_LENGTH_UPLOAD));
  rb_define_const(mCurlInfo, "CONTENT_TYPE",            INT2FIX(CURLINFO_CONTENT_TYPE));
  rb_define_const(mCurlInfo, "HTTPAUTH_AVAIL",          INT2FIX(CURLINFO_HTTPAUTH_AVAIL));
  rb_define_const(mCurlInfo, "PROXYAUTH_AVAIL",         INT2FIX(CURLINFO_PROXYAUTH_AVAIL));
  rb_define_const(mCurlInfo, "OS_ERRNO",                INT2FIX(CURLINFO_OS_ERRNO));
  rb_define_const(mCurlInfo, "NUM_CONNECTS",            INT2FIX(CURLINFO_NUM_CONNECTS));
  rb_define_const(mCurlInfo, "COOKIELIST",              INT2FIX(CURLINFO_COOKIELIST));
  rb_define_const(mCurlInfo, "FTP_ENTRY_PATH",          INT2FIX(CURLINFO_FTP_ENTRY_PATH));


  // Libcurl class
  cLibcurl = rb_define_class_under(mPatron, "Libcurl", rb_cObject);

  rb_define_alloc_func(cLibcurl, libcurl_alloc);

  rb_define_singleton_method(cLibcurl, "version", libcurl_version, 0);

  rb_define_method(cLibcurl, "initialize",  libcurl_initialize, 0);
  rb_define_method(cLibcurl, "escape",      libcurl_escape,     1);
  rb_define_method(cLibcurl, "unescape",    libcurl_unescape,   1);
  rb_define_method(cLibcurl, "setopt",      libcurl_setopt,     2);
  rb_define_method(cLibcurl, "getinfo",     libcurl_getinfo,    1);
  rb_define_method(cLibcurl, "perform",     libcurl_perform,    0);
}
