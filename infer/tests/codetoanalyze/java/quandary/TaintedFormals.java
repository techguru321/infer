/*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

package codetoanalyze.java.quandary;

import com.facebook.infer.builtins.InferTaint;

class Obj {
  Object f;
}

public class TaintedFormals {

  public void callSink(Object formal) {
    InferTaint.inferSensitiveSink(formal);
  }

  // taintedFormal1 and taintedFormal2 were are modeled as tainted
  public void taintedContextBad(String taintedFormal1, Boolean untaintedFormal, Integer taintedFormal2) {
    InferTaint.inferSensitiveSink(taintedFormal1); // should report here
    InferTaint.inferSensitiveSink(taintedFormal2); // should report here
    callSink(taintedFormal1); // should report here
    callSink(taintedFormal2); // should report here

    InferTaint.inferSensitiveSink(untaintedFormal); // should not report here
  }

  public Object taintedContextBad(String taintedFormal) {
    return taintedFormal;
  }

  public void callTaintedContextBad1(String formal) {
    Object tainted = taintedContextBad(formal);
    InferTaint.inferSensitiveSink(tainted);
  }

  public void callTaintedContextBad2() {
    taintedContextBad(null, (Boolean) InferTaint.inferSecretSource(), null);
  }

  public void callTaintedContextOk1() {
    taintedContextBad("foo", null, null);
  }

  // shouldn't report here, otherwise we will double report
  public void callTaintedContextOk2() {
    taintedContextBad(null, null, new Integer(1));
  }

}
