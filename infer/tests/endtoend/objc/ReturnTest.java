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
import static utils.matchers.ResultContainsNoErrorInMethod.doesNotContain;

import com.google.common.collect.ImmutableList;

import org.junit.BeforeClass;
import org.junit.ClassRule;
import org.junit.Test;

import java.io.IOException;

import utils.DebuggableTemporaryFolder;
import utils.InferException;
import utils.InferResults;
import utils.InferRunner;

public class ReturnTest {

  public static final String SRC_FILE =
      "infer/tests/" +
          "codetoanalyze/objc/errors/returnstmt/return_npe_test.m";

  private static ImmutableList<String> inferCmd;

  public static final String NULL_DEREFERENCE = "NULL_DEREFERENCE";

  @ClassRule
  public static DebuggableTemporaryFolder folder =
      new DebuggableTemporaryFolder();

  @BeforeClass
  public static void runInfer() throws InterruptedException, IOException {
    inferCmd = InferRunner.createObjCInferCommand(folder, SRC_FILE);
  }

  @Test
  public void whenInferRunsOnMyClassThenNoNPEIsFound()
      throws InterruptedException, IOException, InferException {
    InferResults inferResults = InferRunner.runInferObjC(inferCmd);
    assertThat(
        "Results should not contain null point dereference",
        inferResults,
        doesNotContain(
            NULL_DEREFERENCE,
            SRC_FILE,
            "aMethod:"
        )
    );
  }
}
