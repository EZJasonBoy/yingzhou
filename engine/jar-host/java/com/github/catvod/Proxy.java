// Adapted from TVBoxOS (AGPL-3.0): where jar spiders find the host's /proxy. Keep names and signatures.
package com.github.catvod;

import tvbox.engine.jarhost.HostBridge;

public class Proxy {

    private static int port = 0;

    public static void set(int port) {
        Proxy.port = port;
    }

    public static int getPort() {
        return port > 0 ? port : HostBridge.port;
    }

    /** The engine listens on loopback; LAN clients reach the same port through the engine's own address. */
    public static String getUrl(boolean local) {
        return "http://127.0.0.1:" + getPort() + "/proxy";
    }
}
