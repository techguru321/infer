/*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/NSObject.h>

@interface A : NSObject
+ (int)bar;
+ (int)scale;
@end
@implementation A

+ (int)bar {
  return 17;
}

+ (int)scale {
  return 19;
}
@end

int foo() { return 23; }

static const int kInsets = foo(); // Error

static float kPadding = [A bar] ? 10.0 : 11.0; // Error

static const float kLineSize = 1 / [A scale]; // Error

static const float ok = 37;

void bla() {
  static const int kInsets = foo(); // Error

  static float kPadding = [A bar] ? 10.0 : 11.0; // Error

  static const float kLineSize = 1 / [A scale]; // Error

  static const float ok = 37;
}
