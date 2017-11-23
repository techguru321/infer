/*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

package org.assertj.core.util;

import javax.annotation.Nullable;

import static com.facebook.infer.builtins.InferBuiltins.assume;

public final class Preconditions {

  public static void checkArgument(
      boolean expression, String errorMessageTemplate, Object... errorMessageArgs) {
    assume(expression);
  }

  public static <T> T checkNotNull(T reference) {
    assume(reference != null);
    return reference;
  }

  public static <T> T checkNotNull(T reference, String message) {
    assume(reference != null);
    return reference;
  }

  public static void checkState(
      boolean expression, String errorMessageTemplate, Object... errorMessageArgs) {
    assume(expression);
  }
}
