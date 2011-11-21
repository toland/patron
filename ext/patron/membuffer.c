#include <ruby.h>
#include <assert.h>
#include "membuffer.h"

#define DEFAULT_CAPACITY  4096
#define MAXVAL(a, b) ((a) > (b) ? (a) : (b))

static int membuffer_ensure_capacity( membuffer* m, size_t length ) {
  size_t new_capacity;
  char* tmp_buf;

  if (m->capacity >= length) { return MB_OK; }

  new_capacity = MAXVAL(m->capacity, DEFAULT_CAPACITY);
  while (new_capacity < length) { new_capacity *= 2; }

  tmp_buf = ruby_xrealloc(m->buf, new_capacity+1);
  if (NULL == tmp_buf) { return MB_OUT_OF_MEMORY; }
  else {
    m->buf = tmp_buf;
    m->capacity = new_capacity;
  }

  return MB_OK;
}

void membuffer_init( membuffer* m ) {
  assert(NULL != m);

  m->buf = NULL;
  m->length = 0;
  m->capacity = 0;
}

void membuffer_destroy( membuffer* m ) {
  if (NULL == m) { return; }

  if (NULL != m->buf) { ruby_xfree(m->buf); }
  m->buf = NULL;
  m->length = 0;
  m->capacity = 0;
}

void membuffer_clear( membuffer* m ) {
  assert(NULL != m);

  if (NULL != m->buf) {
    memset(m->buf, 0, m->capacity+1);
    m->length = 0;
  }
}

int membuffer_insert( membuffer* m, size_t index, const void* src, size_t length ) {
  int rc = MB_OK;
  assert(NULL != m);

  /* sanity checks on the inputs */
  if (index > m->length) { return MB_OUT_OF_BOUNDS; }
  if (NULL == src || 0 == length) { return MB_OK; }

  /* increase capacity if needed */
  rc = membuffer_ensure_capacity( m, m->length + length );
  if (MB_OK != rc) { return rc; }

  /* move data in the buffer to the right of the insertion point */
  memmove( m->buf + index + length, m->buf + index, m->length - index );

  /* copy date into the insertion point */
  memcpy( m->buf + index, src, length );
  m->length += length;
  m->buf[m->length] = 0;  /* null terminate the buffer */

  return MB_OK;
}

int membuffer_append( membuffer* m, const void* src, size_t length ) {
  assert(NULL != m);
  return membuffer_insert( m, m->length, src, length );
}

VALUE membuffer_to_rb_str( membuffer* m ) {
  assert(NULL != m);
  return rb_str_new(m->buf, m->length);
}

