/*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

// TODO: remove this #define, it's here to get a specific version of
// [assert], as others may confuse the clang frontend (t26324545)
#define __STRICT_ANSI__
#include <assert.h>

// We should report here no NPE, but also we should report div0 to show that we
// get the
// non-assertion branch.
int report_div0_and_no_npe(int* p) {
  assert(p);
  return *p / 0;
}
