/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package java.io;

import com.facebook.infer.models.InferUndefined;

public abstract class Writer implements Closeable {

    public Writer append(char c) throws IOException {
        InferUndefined.can_throw_ioexception_void();
        return this;
    }

    public Writer append(CharSequence csq) throws IOException {
        InferUndefined.can_throw_ioexception_void();
        return this;
    }

    public Writer append(CharSequence csq, int start, int end)
            throws IOException {
        InferUndefined.can_throw_ioexception_void();
        return this;
    }

    public void close() throws IOException {
        if (this instanceof OutputStreamWriter) {
            ((OutputStreamWriter) this).close();
        } else if (this instanceof BufferedWriter) {
            ((BufferedWriter) this).close();
        } else if (this instanceof PrintWriter) {
            ((PrintWriter) this).close();
        }
    }

    public void flush() throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(char cbuf[]) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(char cbuf[], int off, int len) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(int c) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(String str) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(String str, int off, int len) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }


}
