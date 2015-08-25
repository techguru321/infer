/*
* Copyright (c) 2015 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*/

package codetoanalyze.java.incremental.child_changed;

class Child {

  Object bar() {
    return null;
  }

  Object dontReanalyze(Object o) {
    return o;
  }

}
