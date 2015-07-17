/*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*/

package java.lang;

import com.facebook.infer.models.InferBuiltins;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.PrintStream;


public final class System {

    private System() {
    }

    public final static InputStream in;

    static {
        byte[] arr = {0};
        in = new ByteArrayInputStream(arr);
    }

    public final static PrintStream out = new PrintStream(
            new ByteArrayOutputStream());

    public final static PrintStream err = new PrintStream(
            new ByteArrayOutputStream());

    public static void exit(int status) {
        InferBuiltins._exit();
    }

}
