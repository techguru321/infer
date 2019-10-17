/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include <algorithm>

int example_function1() { return 1; }

int example_function2() { return 2; }

namespace Shapes {

class Cube {
  int size;

 public:
  void set_size(int);
  int area() { return size * size; };
  void sort(Cube*, unsigned);
};

void Cube::set_size(int s) { size = s; }

void Cube::sort(Cube* xs, unsigned n) {
  std::sort(xs, xs + n, [](Cube a, Cube b) { return (a.area() < b.area()); });
}
} // namespace Shapes
