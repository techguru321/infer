/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package java.io;

import com.facebook.infer.models.InferUndefined;

public abstract class Reader implements Closeable {

    public void close() throws IOException {
        if (this instanceof InputStreamReader) {
            ((InputStreamReader) this).close();
        } else if (this instanceof BufferedReader) {
            ((BufferedReader) this).close();
        } else if (this instanceof FilterReader) {
            ((FilterReader) this).close();
        }
    }

    public int read() throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(char cbuf[]) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(char cbuf[], int off, int len) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(java.nio.CharBuffer target) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public boolean ready() throws IOException {
        return InferUndefined.can_throw_ioexception_boolean();
    }

    public void reset() throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public long skip(long n) throws IOException {
        return InferUndefined.can_throw_ioexception_long();
    }

}
