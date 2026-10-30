package dev.amirzr.flutter_v2ray_client.v2ray.utils;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Extract only the endpoint of an app-owned outbound, without exposing its credentials. */
public final class OutboundEndpoint {
    public final String address;
    public final int port;

    private OutboundEndpoint(String address, int port) {
        this.address = address;
        this.port = port;
    }

    public static OutboundEndpoint from(JSONObject outbound) throws JSONException {
        JSONObject settings = outbound.getJSONObject("settings");
        JSONObject endpoint;
        switch (outbound.getString("protocol")) {
            case "vless":
            case "vmess":
                endpoint = onlyServer(settings.getJSONArray("vnext"));
                break;
            case "trojan":
            case "shadowsocks":
                endpoint = onlyServer(settings.getJSONArray("servers"));
                break;
            case "hysteria":
                if (settings.getInt("version") != 2) throw invalid();
                endpoint = settings;
                break;
            default:
                throw invalid();
        }
        String address = endpoint.getString("address");
        int port = endpoint.getInt("port");
        if (address.isEmpty() || address.length() > 253 || port < 1 || port > 65535) throw invalid();
        for (int index = 0; index < address.length(); index++) {
            if (Character.isISOControl(address.charAt(index)) || Character.isWhitespace(address.charAt(index))) throw invalid();
        }
        return new OutboundEndpoint(address, port);
    }

    private static JSONObject onlyServer(JSONArray values) throws JSONException {
        if (values.length() != 1) throw invalid();
        return values.getJSONObject(0);
    }

    private static JSONException invalid() {
        return new JSONException("Unsupported or invalid VPN endpoint");
    }

    @Override public String toString() { return "OutboundEndpoint(redacted)"; }
}
