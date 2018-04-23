/*
 * Copyright (c) 2018 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

// Tests that exercise precision of the analysis on control variables

// -- We computed infinity before for the following two tests--

// Loop's execution count doesn't depend on values of p,t,k
int loop_no_dep1(int k) {
  int p = 0;
  int t = 2 + k;
  for (int i = 0; i < 100; i++) {
    p++;
  }
  return p;
}

int foo(int i, int j) { return i + j; }

// Loop's execution count doesn't depend on values of p,t,k
int loop_no_dep2(int k) {
  int p = 0;
  int t = foo(p, k);
  for (int i = 0; i < 100; i++) {
    p++;
  }
  return p;
}

// -- Below examples didn't work before, but enhancing CF analysis
// makes the analysis much more precise and we can get proper bounds
//
// This example works now because even though j in [-oo.+oo],
// since control vars={k} (notice that we will remove {p,j} in the else branch),
// we ignore j and find the right bound for the inner loop
int if_bad(int j) {
  int p = 10;
  if (p < 10 + j) {
    p++;
  } else {
    p = j + 3;
    for (int k = 0; k < 10; k++) {
      j += 3;
    }
  }
  return p;
}

// Notice that removing {j,p} above doesn't create any problems if we are in a
// loop that depends on them. E.g.: below we still depend on {j} but in the
// conditional prune statement, we will remove the temp. var that map to inner
// {j}, not the outer {j}
int if_bad_loop() {
  int p = 10;
  for (int j = 0; j < 5; j++) {
    if (j < 2) {
      p++;
    } else {
      p = 3;
      for (int k = 0; k < 10; k++) {
        int m = 0;
      }
    }
  }
  return p;
}

// The fake dependency btw first and second loop disappeared and we can get a
// proper bound
//
int two_loops() {
  int p = 10;
  int k = 3;
  int t = 2 + k;
  for (int j = 0; j < 6; j++) {
    k++;
  }
  for (int i = 0; i < 100; i++) {
    p = 3;
  }
  return p;
}

// We don't get a false dependency to m (hence p) since
// for if statements, we don't add prune variables as dependency
int loop_despite_inferbo(int p) {

  int k = 100;
  for (int i = 0; i < k; i++) {
    int m = p + 3;
    if (m < 14) {
      p += 9;
    }
  }
  return p;
}

// -- Below examples should have worked, but due to the imprecision/weakness
//  in inferbo's relational analysis, they don't

// We can get program point A's execution count as 5, however
// due to the weakness in inferbo's relational analysis `i` is in [0, +oo]
int nested_loop() {
  int k = 0;
  for (int i = 0; i < 5; i++) {
  A:
    k = 0;
    for (int j = 0; j < 100; j++) {
      k = 3;
    }
  }
  return k;
}

// Unlike the above program, B will be inside the inner loop, hence executed
// around 105 times
int simulated_nested_loop(int p) {
  int k = 0;
  int t = 5;
  int j = 0;
  for (int i = 0; i < 5; i++) {
  B:
    t = 3;
    j++;
    if (j < 100)
      goto B; // continue;
  }
  return k;
}

// B will be inside the inner loop and executed ~500 times
int simulated_nested_loop_more_expensive(int p) {
  int k = 0;
  int t = 5;
  int j = 0;
  for (int i = 0; i < 5; i++) {
  B:
    t = 3;
    j++;
    if (j < 100)
      goto B; // continue;
    else {
      j = 0;
    }
  }
  return k;
}
