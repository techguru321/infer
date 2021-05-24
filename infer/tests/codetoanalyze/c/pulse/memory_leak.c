/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
#include <stdlib.h>

void malloc_no_free_bad() { int* p = malloc(sizeof(p)); }

int* malloc_returned_ok() {
  int* p = malloc(sizeof(p));
  return p;
}

void malloc_out_parameter_ok(int** x) { *x = (int*)malloc(sizeof(int)); }

void malloc_out_parameter_local_mutation_ok(int** x) {
  *x = (int*)malloc(sizeof(int));
  x = NULL; // not visible from the outside
}

void malloc_out_parameter_local_mutation_bad(int** x) {
  *x = (int*)malloc(sizeof(int));
  *x = NULL;
}

void malloc_then_free_ok() {
  int* p = malloc(sizeof(p));
  if (p) {
    *p = 5;
    free(p);
  }
}

int* create_p() {
  int* p = malloc(sizeof(p));
  return p;
}

void malloc_interproc_no_free_bad() { int* p = create_p(); }

void malloc_interproc_no_free_bad2() {
  int* p = malloc(sizeof(p));
  int z = 3;
  int y = 4;
  int* q = p;
}

void malloc_formal_leak_bad(int* x) { x = (int*)malloc(sizeof(int*)); }

static void* (*const malloc_func)(size_t) = malloc;
static void (*const free_func)(void*) = free;

void* malloc_via_ptr(size_t size) {
  void* ret = NULL;

  if (size <= 0) {
    return NULL;
  }

  ret = malloc_func(size);
  return ret;
}

void free_via_ptr(void* x) { free_func(x); }

void malloc_ptr_leak_bad() { int* p = (int*)malloc_via_ptr(sizeof(int)); }

void malloc_ptr_no_check_leak_bad() {
  int* p = (int*)malloc_via_ptr(sizeof(int));
  *p = 42;
}

void malloc_ptr_free_ok() {
  int* p = (int*)malloc_via_ptr(sizeof(int));
  free(p);
}

void malloc_ptr_free_ptr_ok() {
  int* p = (int*)malloc_via_ptr(sizeof(int));
  free_via_ptr(p);
}

void alias_ptr_free_ok(int* out, int flag) {
  int* y;
  if (flag) {
    y = (int*)malloc(sizeof(int));
  } else {
    y = out;
  }
  if (y && y != out) {
    free(y);
  }
}

void report_leak_in_correct_line_bad(int* x) {
  x = (int*)malloc(sizeof(int));
  if (x != NULL) {
    return; // should report leak at this line
  }
  free(x);
}

void* realloc_wrapper(void* p, size_t size) { return realloc(p, size); }

void realloc_free_ok() {
  int* p = (int*)malloc(sizeof(int));
  int* q = realloc_wrapper(p, sizeof(int));
  free(q);
}

void realloc_no_free_bad() {
  int* p = (int*)malloc(sizeof(int));
  int* q = realloc_wrapper(p, sizeof(int));
}

void realloc_no_check_bad() {
  int* p = (int*)malloc(sizeof(int));
  int* q = realloc_wrapper(p, sizeof(int));
  *q = 42;
  free(q);
}
