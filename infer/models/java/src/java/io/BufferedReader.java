/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package java.io;

import com.facebook.infer.models.InferUndefined;

public class BufferedReader extends Reader {

    private Reader in;

    public BufferedReader(Reader in, int sz) {
        this.in = in;
    }

    public BufferedReader(Reader in) {
        this.in = in;
    }

    public void close() throws IOException {
        if (in instanceof InputStreamReader)
            ((InputStreamReader) in).close();
    }

    public int read() throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(char cbuf[]) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(char[] cbuf, int off, int len) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public String readLine() throws IOException {
        return InferUndefined.can_throw_ioexception_string();
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
