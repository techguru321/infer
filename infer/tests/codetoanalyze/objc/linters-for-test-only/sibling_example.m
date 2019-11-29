/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
#import <Foundation/Foundation.h>

int x;

@interface SiblingExample

@end

#define LINK_REQUIRE(NAME)                                 \
  extern char Linkable_##NAME;                             \
  extern const void* const OS_WEAK OS_CONCAT(Link_, NAME); \
  OS_USED const void* const OS_WEAK OS_CONCAT(Link_, NAME) = &Linkable_##NAME;

@interface SiblingExample (Cat1)
- (void)foo:(int)themeProvider;

@end

LINK_REQUIRE(SiblingExampl);
@interface SiblingExample (Cat2)
- (void)foo:(int)themeProvider;

@end
