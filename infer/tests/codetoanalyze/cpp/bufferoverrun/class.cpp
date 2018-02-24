/*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
class my_class {
  int idx;
  int arr[10];

  void set_a(int n) { idx = n; }

  int id(int n) { return n; }

 public:
  int access_Bad() {
    set_a(10);
    return arr[idx];
  }

  int access2_Bad() {
    int n = 10;
    return arr[id(n)];
  }

  int access_nth(int n) { return arr[n]; }
};

void access_after_new_Good() {
  my_class* x = new my_class();
  x->access_nth(5);
}

void access_after_new_Bad() {
  my_class* x = new my_class();
  x->access_nth(15);
}

#include <stdlib.h>

class my_class2 {
 public:
  int a[5];
};

void array_member_malloc_Good() {
  my_class2* x = (my_class2*)malloc(sizeof(my_class2));
  x->a[0] = 0;
}

void array_member_malloc_Bad() {
  my_class2* x = (my_class2*)malloc(sizeof(my_class2));
  x->a[10] = 0;
}

class my_class3 {
 public:
  my_class2 b;
};

void array_member_malloc2_Bad() {
  my_class3* x = (my_class3*)malloc(sizeof(my_class3));
  x->b.a[10] = 0;
}

#include <new>

void placement_new_Good() {
  char* mem = (char*)malloc(sizeof(my_class2));
  my_class2* x = new (mem) my_class2();
  x->a[0] = 0;
}

void placement_new_Bad() {
  char* mem = (char*)malloc(sizeof(my_class2));
  my_class2* x = new (mem) my_class2();
  x->a[10] = 0;
}
