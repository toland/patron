
#ifndef PATRON_MEMBUFER_H
#define PATRON_MEMBUFER_H

#include <stdlib.h>

#define MB_OK             0
#define MB_OUT_OF_MEMORY  1
#define MB_OUT_OF_BOUNDS  2

/**
 * Implementation of a simple memory buffer for collecting the response body
 * and headers from a curl request. The memory buffer will grow to accomodate
 * the data inserted into it.
 *
 * When the memory buffer needs more capacity, it will reallocate memory from
 * the heap. It will request twice it's current capacity.
 */
typedef struct {
  char    *buf;
  size_t   length;
  size_t   capacity;
} membuffer;

/**
 * Initialize the memory buffer by setting default values of 0 for the length
 * and capacity.
 */
void membuffer_init( membuffer* m );

/**
 * Free any memory used by the memory buffer.
 */
void membuffer_destroy( membuffer* m );

/**
 * Clear the contents of the memory buffer. The length will be set to zero,
 * but the capacity will remain unchanged - i.e. memory will not be freed by
 * his method.
 */
void membuffer_clear( membuffer* m );

/**
 * Attempt to insert the given _src_ data into the memory buffer at the given
 * _index_. This method will shift data in the memory buffer to the right in
 * order to insert the _src_ data.
 *
 * This method will fail if the _index_ is out of bounds for the memory
 * buffer, if the _src_ is NULL or the _length_ to insert is 0. This method
 * can also fail if the memory buffer needs to expand it's capacity but no
 * memory is available.
 *
 * Return Codes:
 *   MB_OK
 *   MB_OUT_OF_MEMORY
 *   MB_OUT_OF_BOUNDS
 */
int membuffer_insert( membuffer* m, size_t index, const void* src, size_t length );

/**
 * Append the given _src_ data to the end of the memory buffer. This method
 * calls `membuffer_insert` to append the data.
 *
 * Return Codes:
 *   MB_OK
 *   MB_OUT_OF_MEMORY
 */
int membuffer_append( membuffer* m, const void* src, size_t length );

/**
 * Convert the memory buffer into a Ruby String instance. This method will
 * return an empty String instance if the memory buffer is empty. This method
 * will never return Qnil.
 */
VALUE membuffer_to_rb_str( membuffer* m );

#endif

