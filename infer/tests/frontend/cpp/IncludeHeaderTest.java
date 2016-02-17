/*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

package frontend.cpp;

import org.junit.Rule;
import org.junit.Test;

import java.io.IOException;

import utils.DebuggableTemporaryFolder;
import utils.InferException;
import utils.ClangFrontendUtils;

public class IncludeHeaderTest {

  String basePath = "infer/tests/codetoanalyze/cpp/frontend/include_header/";

  @Rule
  public DebuggableTemporaryFolder folder = new DebuggableTemporaryFolder();

  void frontendTest(String fileRelative) throws InterruptedException, IOException, InferException {
    ClangFrontendUtils.createAndCompareCppDotFiles(folder, basePath + fileRelative);
  }

  @Test
  public void testIncludeOnlyDotFilesMatch()
      throws InterruptedException, IOException, InferException {
    frontendTest("include_only.cpp");
  }

  @Test
  public void testIncludeTemplDotFilesMatch()
      throws InterruptedException, IOException, InferException {
    frontendTest("include_templ.cpp");
  }

}
