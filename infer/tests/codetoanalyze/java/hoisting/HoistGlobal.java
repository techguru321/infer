/*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
class HoistGlobal {

  public static int svar = 0;

  int read_global() {
    return svar;
  }

  class Foo {
    void set() {
      svar = 5;
    }

    int read_global() {
      return svar;
    }
  }

  int global_modification_dont_hoist(int size) {
    Foo f = new Foo();
    int d = 0;
    for (int i = 0; i < size; i++) {
      d += read_global(); // don't hoist since set() changes a global var in the loop
      f.set();
      f.read_global(); // don't hoist
    }
    return d;
  }

  void call_global_modification_dont_hoist(int size) {
    for (int i = 0; i < size; i++) {
      global_modification_dont_hoist(size);
    }
  }
}
