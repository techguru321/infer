/*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

package codetoanalyze.java.checkers;

import com.facebook.infer.annotation.Expensive;
import com.facebook.infer.annotation.PerformanceCritical;

interface I {
  void foo();
}

class A implements I {

  @SuppressWarnings("infer")
  // Suppressing the sub-typing violation warning here as foo() is not annotated as @Expensive
  // in the interface. This report is legit but is not relevant for the current test.
  @Expensive
  public void foo() {}

}

class B extends A implements I {
  public void foo() {}
}

public class ExpensiveInheritanceExample {

  // The objective of this test is to document the limitations of the checker, which just
  // implements a type system. This means that the checker is flow insensitive and is only based
  // on the static type information. Especially, it does not try to resolve dynamic dispatch.
  // However, the checker is still exhaustive thanks to the sub-typing rule for
  // the @Expensive annotation.
  @PerformanceCritical
  void shouldNotReportBecauseInterfaceNotAnnotated(I i) {
    i.foo();
  }

  @PerformanceCritical
  void reportsBecauseFooIsExpensiveInA(A a) {
    a.foo();
  }

  @PerformanceCritical
  void doesNotreportBecauseFooIsNotExpensiveInB(B b) {
    b.foo();
  }

  native B createB();

  A actuallyReturnsObjectOfTypeB() {
    return createB();
  }

  @PerformanceCritical
  void reportsAssumingObjectOfTypeA() {
    A a = actuallyReturnsObjectOfTypeB();
    a.foo();
  }

  @PerformanceCritical
  void doesReportBecauseTypeFlowInsensitive(A a) {
    if (a instanceof B) {
      a.foo();
    }
  }

}
