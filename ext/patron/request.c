#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cRequest = Qnil;
static VALUE mCurlOpts = Qnil;
static VALUE mCurlInfo = Qnil;

struct curl_state {
  CURL* handle;
};


//------------------------------------------------------------------------------
// Callback support
//

static size_t request_write_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
  size_t result = size * nmemb;
  rb_funcall(proc, rb_intern("call"), 1, rb_str_new(stream, result));
  return result;
}

static size_t request_read_shim(char* stream, size_t size, size_t nmemb, VALUE proc) {
  size_t result = size * nmemb;
  VALUE string = rb_funcall(proc, rb_intern("call"), 1, result);
  size_t len = RSTRING(string)->len;
  memcpy(stream, RSTRING(string)->ptr, len);
  return len;
}


//------------------------------------------------------------------------------
// Object allocation
//

void request_free(struct curl_state *curl) {
  curl_easy_cleanup(curl->handle);
  free(curl);
}

VALUE request_alloc(VALUE klass) {
  struct curl_state* curl;
  VALUE obj = Data_Make_Struct(klass, struct curl_state, NULL, request_free, curl);
  return obj;
}


//------------------------------------------------------------------------------
// Method implementations
//

VALUE request_version(VALUE klass) {
  char* value = curl_version();
  return rb_str_new2(value);
}

VALUE request_initialize(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl->handle = curl_easy_init();

  return self;
}

VALUE request_escape(VALUE self, VALUE value) {
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

VALUE request_unescape(VALUE self, VALUE value) {
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

VALUE request_setopt(VALUE self, VALUE optval, VALUE parameter) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  int option = FIX2INT(optval);
  switch (option) {
    case CURLOPT_READFUNCTION:
      curl_easy_setopt(curl, CURLOPT_READFUNCTION, &request_read_shim);
      curl_easy_setopt(curl, CURLOPT_READDATA, parameter);
      break;

    case CURLOPT_WRITEFUNCTION:
      curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &request_write_shim);
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, parameter);
      break;

    case CURLOPT_HEADERFUNCTION:
      curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &request_write_shim);
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

VALUE request_getinfo(VALUE self, VALUE infoval) {
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

VALUE request_perform(VALUE self) {
  struct curl_state *curl;
  Data_Get_Struct(self, struct curl_state, curl);

  curl_easy_perform(curl->handle);

  return Qnil;
}


//------------------------------------------------------------------------------
// Extension initialization
//

void Init_request() {
  curl_global_init(CURL_GLOBAL_NOTHING);

  mPatron = rb_define_module("Patron");

  // Curl option constants
  mCurlOpts = rb_define_module_under(mPatron, "CurlOpts");

#define define_curl_opt(X) rb_define_const(mCurlOpts, #X, INT2FIX(CURLOPT_##X))

  define_curl_opt(VERBOSE);
  define_curl_opt(HEADER);
  define_curl_opt(STDERR);
  define_curl_opt(FAILONERROR);
  define_curl_opt(URL);
  define_curl_opt(PROXY);
  define_curl_opt(PROXYPORT);
  define_curl_opt(PROXYTYPE);
  define_curl_opt(HTTPPROXYTUNNEL);
  define_curl_opt(INTERFACE);
  define_curl_opt(LOCALPORT);
  define_curl_opt(LOCALPORTRANGE);
  define_curl_opt(DNS_CACHE_TIMEOUT);
  define_curl_opt(BUFFERSIZE);
  define_curl_opt(PORT);
  define_curl_opt(TCP_NODELAY);
  define_curl_opt(NETRC);
  define_curl_opt(USERPWD);
  define_curl_opt(PROXYUSERPWD);
  define_curl_opt(HTTPAUTH);
  define_curl_opt(PROXYAUTH);
  define_curl_opt(AUTOREFERER);
  define_curl_opt(ENCODING);
  define_curl_opt(FOLLOWLOCATION);
  define_curl_opt(UNRESTRICTED_AUTH);
  define_curl_opt(MAXREDIRS);
  define_curl_opt(PUT);
  define_curl_opt(POST);
  define_curl_opt(POSTFIELDS);
  define_curl_opt(POSTFIELDSIZE);
  define_curl_opt(HTTPPOST);
  define_curl_opt(REFERER);
  define_curl_opt(USERAGENT);
  define_curl_opt(HTTPHEADER);
  define_curl_opt(HTTP200ALIASES);
  define_curl_opt(COOKIE);
  define_curl_opt(COOKIEFILE);
  define_curl_opt(COOKIEJAR);
  define_curl_opt(COOKIESESSION);
  define_curl_opt(COOKIELIST);
  define_curl_opt(HTTPGET);
  define_curl_opt(HTTP_VERSION);
  define_curl_opt(IGNORE_CONTENT_LENGTH);
  define_curl_opt(HTTP_CONTENT_DECODING);
  define_curl_opt(HTTP_TRANSFER_DECODING);

  define_curl_opt(READFUNCTION);
  define_curl_opt(WRITEFUNCTION);
  define_curl_opt(HEADERFUNCTION);
  define_curl_opt(PROGRESSFUNCTION);
  define_curl_opt(DEBUGFUNCTION);


  // Curl info constants
  mCurlInfo = rb_define_module_under(mPatron, "CurlInfo");

#define define_curl_info(X) rb_define_const(mCurlInfo, #X, INT2FIX(CURLINFO_##X))

  define_curl_info(EFFECTIVE_URL);
  define_curl_info(RESPONSE_CODE);
  define_curl_info(HTTP_CONNECTCODE);
  define_curl_info(FILETIME);
  define_curl_info(TOTAL_TIME);
  define_curl_info(NAMELOOKUP_TIME);
  define_curl_info(CONNECT_TIME);
  define_curl_info(PRETRANSFER_TIME);
  define_curl_info(STARTTRANSFER_TIME);
  define_curl_info(REDIRECT_TIME);
  define_curl_info(REDIRECT_COUNT);
  define_curl_info(SIZE_UPLOAD);
  define_curl_info(SIZE_DOWNLOAD);
  define_curl_info(SPEED_DOWNLOAD);
  define_curl_info(SPEED_UPLOAD);
  define_curl_info(HEADER_SIZE);
  define_curl_info(REQUEST_SIZE);
  define_curl_info(SSL_VERIFYRESULT);
  define_curl_info(SSL_ENGINES);
  define_curl_info(CONTENT_LENGTH_DOWNLOAD);
  define_curl_info(CONTENT_LENGTH_UPLOAD);
  define_curl_info(CONTENT_TYPE);
  define_curl_info(HTTPAUTH_AVAIL);
  define_curl_info(PROXYAUTH_AVAIL);
  define_curl_info(OS_ERRNO);
  define_curl_info(NUM_CONNECTS);
  define_curl_info(COOKIELIST);
  define_curl_info(FTP_ENTRY_PATH);


  // Request class
  cRequest = rb_define_class_under(mPatron, "Request", rb_cObject);

  rb_define_alloc_func(cRequest, request_alloc);

  rb_define_singleton_method(cRequest, "version", request_version, 0);

  rb_define_method(cRequest, "initialize",  request_initialize, 0);
  rb_define_method(cRequest, "escape",      request_escape,     1);
  rb_define_method(cRequest, "unescape",    request_unescape,   1);
  rb_define_method(cRequest, "setopt",      request_setopt,     2);
  rb_define_method(cRequest, "getinfo",     request_getinfo,    1);
  rb_define_method(cRequest, "perform",     request_perform,    0);
}
