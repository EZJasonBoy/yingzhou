// Adapted from TVBoxOS (AGPL-3.0): DNS with config `hosts` overrides, used by OkHttp.client(). Keep names and signatures.
package com.github.catvod.net;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import okhttp3.Dns;

public class OkDns implements Dns {

    private final ConcurrentHashMap<String, String> hosts = new ConcurrentHashMap<>();

    public void addAll(List<String> hosts) {
        if (hosts == null) return;
        for (String host : hosts) {
            if (host == null) continue;
            String[] splits = host.split("=", 2);
            if (splits.length == 2) this.hosts.put(splits[0].trim(), splits[1].trim());
        }
    }

    public void clear() {
        hosts.clear();
    }

    private String get(String hostname) {
        String target = hosts.get(hostname);
        if (target != null) return target;
        for (Map.Entry<String, String> entry : hosts.entrySet()) {
            if (hostname.contains(entry.getKey())) return entry.getValue();
        }
        return hostname;
    }

    @Override
    public List<InetAddress> lookup(String hostname) throws UnknownHostException {
        // TVBoxOS asks its DoH client or the system here. The engine's client resolves with the active config's
        // `hosts` and the user's DNS choice (tvbox.engine.core.net.ConfigNetwork), so that is who is asked.
        okhttp3.OkHttpClient base = tvbox.engine.jarhost.HostBridge.baseClient;
        Dns next = base != null ? base.dns() : Dns.SYSTEM;
        return next.lookup(get(hostname));
    }
}
