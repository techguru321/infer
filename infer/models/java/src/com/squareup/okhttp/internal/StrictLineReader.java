/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package com.squareup.okhttp.internal;

import com.facebook.infer.models.InferUndefined;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.Charset;

public class StrictLineReader implements Closeable {

    private InputStream in;
    private Charset charset;
    private byte[] buf;

    public StrictLineReader(InputStream in, Charset charset) {
        this(in, 8192, charset);
    }

    public StrictLineReader(InputStream in, int capacity, Charset charset) {
        if (in == null) {
            throw new NullPointerException();
        }
        if (capacity < 0) {
            throw new IllegalArgumentException("capacity <= 0");
        }

        this.in = in;
        this.charset = charset;
        buf = new byte[capacity];
    }

    public void close() throws IOException {
        in.close();
        InferUndefined.can_throw_ioexception_void();
    }

    public String readLine() throws IOException {
        return InferUndefined.can_throw_ioexception_string();
    }


    public int readInt() throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }


}

