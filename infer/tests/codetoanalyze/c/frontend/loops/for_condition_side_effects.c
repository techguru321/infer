/*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*/

int main() {
  int j = 0;
  int i = 0;
  for (int b=3; (b=10); i++) {
      j += j;
    }
  return 0;
}
