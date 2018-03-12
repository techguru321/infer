/*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
#include <stdint.h>

void modulo_signed_Bad(int i) {
  char arr[5];
  arr[i % 5] = 123;
}

void modulo_signed_Good(int i) {
  char arr[5];
  if (i >= 0) {
    arr[i % 5] = 123;
  }
}

void modulo_signed_neg_Bad(int i) {
  char arr[5];
  arr[i % -5] = 123;
}

void modulo_signed_neg_Good(int i) {
  char arr[5];
  if (i >= 0) {
    arr[i % -5] = 123;
  }
}

void modulo_signed_Good2(int i) {
  char arr[5];
  int j = i % 5;
  if (j >= 0) {
    arr[j] = 123;
  }
}

void modulo_unsigned_Good(unsigned int i) {
  char arr[5];
  arr[i % 5] = 123;
}

void modulo_unsigned_short_Good(uint16_t i) {
  char arr[5];
  arr[i % 5] = 123;
}

void modulo_signed_var_Bad_FN(unsigned int len, int i) {
  char arr[len];
  arr[i % len] = 123;
}

void modulo_unsigned_var_Good(unsigned int len, unsigned int i) {
  char arr[len];
  arr[i % len] = 123;
}

unsigned int modulo_unsigned(unsigned int a, unsigned int b) { return a % b; }

void modulo_call_Good(unsigned int len, unsigned int i) {
  char arr[len];
  arr[modulo_unsigned(i, len)] = 123;
}

int modulo_signed(int a, int b) { return a % b; }

void modulo_call_Bad_FN(unsigned int len, int i) {
  char arr[len];
  arr[modulo_signed(i, len)] = 123;
}

int division_of_zero_Good(int x) {
  int i = 4 * x;
  i /= 2;
  i /= 2;
  return i;
}

/* While the most precise return value is
   - "2*i+1"    if 0 <= i < 10,
   - "0"        o.w.
   Inferbo returns [1+min(-1,s0),10+max(-10,s1)] where i is [s0,s1]. */
int plus_linear_min(int i) { /* i |-> [s0,s1] */
  int linear = i + 1; /* linear |-> [s0+1,s1+1] */
  if (i >= 0 && i < 10) { /* i |-> [max(0,s0),min(9,s1)] */
    return linear + i; /* return |-> [s0+1,s1+10] */
  }
  return 0;
}

void plus_linear_min_Good() {
  int a[20];
  a[plus_linear_min(9)] = 1;
}

void plus_linear_min_Bad() {
  int a[19];
  a[plus_linear_min(9)] = 1;
}

void plus_linear_min2_Good_FP() {
  int a[10];
  a[plus_linear_min(4)] = 1;
}

void plus_linear_min3_Good_FP() {
  int a[20];
  a[plus_linear_min(15)] = 1;
}
