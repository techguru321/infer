/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package java.net;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

public class Socket {

    SocketImpl impl;

    public Socket() {
        try {
            setImpl();
        } catch (IOException e) {
        }
    }

    void setImpl() throws IOException {
        impl = new PlainSocketImpl();
    }

    public Socket(Proxy proxy) {
        this();
    }

    protected Socket(SocketImpl impl) throws SocketException {
        this();
    }

    public Socket(String host, int port) throws UnknownHostException,
            IOException {
        this();
    }

    public Socket(InetAddress address, int port) throws IOException {
        this();
    }

    public Socket(String host, int port, InetAddress localAddr, int localPort)
            throws IOException {
        this();
    }

    public Socket(InetAddress address, int port, InetAddress localAddr,
                  int localPort) throws IOException {
        this();
    }

    public Socket(String host, int port, boolean stream) throws IOException {
        this();
    }

    public Socket(InetAddress host, int port, boolean stream)
            throws IOException {
        this();
    }

    public InputStream getInputStream() throws IOException {
        return ((PlainSocketImpl) impl).getInputStream();
    }

    public OutputStream getOutputStream() throws IOException {
        return ((PlainSocketImpl) impl).getOutputStream();
    }

    public synchronized void close() throws IOException {
        ((PlainSocketImpl) impl).close();
    }
}
