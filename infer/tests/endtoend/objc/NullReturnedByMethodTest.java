/*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
 */

package endtoend.objc;

import static org.hamcrest.MatcherAssert.assertThat;
import static utils.matchers.ResultContainsErrorInMethod.contains;

import com.google.common.collect.ImmutableList;

import org.junit.BeforeClass;
import org.junit.ClassRule;
import org.junit.Test;

import java.io.IOException;

import utils.DebuggableTemporaryFolder;
import utils.InferException;
import utils.InferResults;
import utils.InferRunner;

public class NullReturnedByMethodTest {

  public static final String FILE =
      "infer/tests/codetoanalyze/objc/errors/npe/null_returned_by_method.m";

  private static ImmutableList<String> inferCmdFraction;

  public static final String NULL_DEREFERENCE = "NULL_DEREFERENCE";

  @ClassRule
  public static DebuggableTemporaryFolder folderFraction =
      new DebuggableTemporaryFolder();

  @BeforeClass
  public static void runInfer() throws InterruptedException, IOException {
    inferCmdFraction = InferRunner.createObjCInferCommand(
        folderFraction,
        FILE);

  }

  @Test
  public void whenInferRunsOnTest1ThenNpeIsFound()
      throws InterruptedException, IOException, InferException {
    InferResults inferResults = InferRunner.runInferObjC(inferCmdFraction);
    assertThat(
        "Results should contain null pointer dereference error",
        inferResults,
        contains(
            NULL_DEREFERENCE,
            FILE,
            "test1"
        )
    );
  }

}
