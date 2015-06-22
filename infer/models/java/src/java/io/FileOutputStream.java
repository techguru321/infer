/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package java.io;

import com.facebook.infer.models.InferBuiltins;
import com.facebook.infer.models.InferUndefined;

import java.nio.FileChannelImpl;
import java.nio.channels.FileChannel;


public class FileOutputStream extends OutputStream {

    private FileDescriptor fd;
    private FileChannel channel;

    private void init() {
        InferBuiltins.__set_file_attribute(this);
    }

    public FileOutputStream(String name) throws FileNotFoundException {
        if (InferUndefined.boolean_undefined()) {
            init();
        } else {
            throw new FileNotFoundException();
        }
    }

    public FileOutputStream(String name, boolean append) throws FileNotFoundException {
        if (InferUndefined.boolean_undefined()) {
            init();
        } else {
            throw new FileNotFoundException();
        }
    }

    public FileOutputStream(File file) throws FileNotFoundException {
        if (InferUndefined.boolean_undefined()) {
            init();
        } else {
            throw new FileNotFoundException();
        }
    }

    public FileOutputStream(File file, boolean append)
            throws FileNotFoundException {
        if (InferUndefined.boolean_undefined()) {
            init();
        } else {
            throw new FileNotFoundException();
        }
    }

    public FileOutputStream(FileDescriptor fdObj) {
        init();
    }

    public FileChannel getChannel() {
        channel = new FileChannelImpl(this, fd, InferUndefined.int_undefined());
        return channel;
    }

    public void write(int b) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(byte b[]) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void write(byte b[], int off, int len) throws IOException {
        InferUndefined.can_throw_ioexception_void();
    }

    public void close() throws IOException {
        InferBuiltins.__set_mem_attribute(this);
        InferUndefined.can_throw_ioexception_void();
    }

}
