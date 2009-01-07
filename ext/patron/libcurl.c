#include <ruby.h>
#include <curl/curl.h>

static VALUE mPatron = Qnil;
static VALUE cLibcurl = Qnil;

// Prototype for the initialization method - Ruby calls this, not you
void Init_libcurl();

// Prototype for our method 'test1' - methods are prefixed by 'method_' here
VALUE method_test1(VALUE self);

// The initialization method for this module
void Init_libcurl() {
    mPatron = rb_define_module("Patron");
    cLibcurl = rb_define_class_under(mPatron, "Libcurl", rb_cObject);

	rb_define_method(cLibcurl, "test1", method_test1, 0);
}

// Our 'test1' method.. it simply returns a value of '10' for now.
VALUE method_test1(VALUE self) {
	int x = 10;
	return INT2NUM(x);
}
