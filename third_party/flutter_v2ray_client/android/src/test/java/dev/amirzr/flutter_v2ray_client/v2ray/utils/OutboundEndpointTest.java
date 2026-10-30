package dev.amirzr.flutter_v2ray_client.v2ray.utils;

import static org.junit.Assert.*;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

public class OutboundEndpointTest {
    private JSONObject outbound(String protocol, String field) throws Exception {
        JSONObject endpoint = new JSONObject().put("address", "fixture.example").put("port", 443);
        JSONObject settings = field == null ? endpoint.put("version", 2)
                : new JSONObject().put(field, new JSONArray().put(endpoint));
        return new JSONObject().put("protocol", protocol).put("settings", settings);
    }

    @Test public void extractsEverySupportedEndpointShape() throws Exception {
        for (String protocol : new String[]{"vless", "vmess", "trojan", "shadowsocks", "hysteria"}) {
            String field = protocol.equals("hysteria") ? null
                    : protocol.equals("vless") || protocol.equals("vmess") ? "vnext" : "servers";
            OutboundEndpoint result = OutboundEndpoint.from(outbound(protocol, field));
            assertEquals("fixture.example", result.address);
            assertEquals(443, result.port);
            assertEquals("OutboundEndpoint(redacted)", result.toString());
        }
    }

    @Test public void refusesUnknownAndWrongEndpointShapes() throws Exception {
        for (JSONObject value : new JSONObject[]{outbound("socks", "servers"), outbound("hysteria", "vnext"),
                outbound("trojan", "vnext"), outbound("vmess", "servers"),
                outbound("hysteria", null).put("settings", new JSONObject().put("version", 1))}) {
            try { OutboundEndpoint.from(value); fail("accepted an invalid endpoint"); }
            catch (org.json.JSONException expected) { /* No credentials in errors. */ }
        }
    }

    @Test public void refusesInvalidEndpointAndMultipleServers() throws Exception {
        for (Object port : new Object[]{0, -1, 65536}) {
            JSONObject value = outbound("hysteria", null);
            value.getJSONObject("settings").put("port", port);
            try { OutboundEndpoint.from(value); fail("accepted invalid port"); }
            catch (org.json.JSONException expected) { }
        }
        JSONObject multiple = outbound("vless", "vnext");
        multiple.getJSONObject("settings").getJSONArray("vnext").put(new JSONObject());
        try { OutboundEndpoint.from(multiple); fail("accepted multiple servers"); }
        catch (org.json.JSONException expected) { }
    }
}
