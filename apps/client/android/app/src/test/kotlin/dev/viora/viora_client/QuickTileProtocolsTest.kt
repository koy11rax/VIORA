package dev.viora.viora_client

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.fail
import org.junit.Test

class QuickTileProtocolsTest {
    private fun config(protocol: String): JSONObject {
        val endpoint = JSONObject().put("address", "fixture.example").put("port", 443)
        val settings = when (protocol) {
            "vless", "vmess" -> JSONObject().put("vnext", JSONArray().put(endpoint))
            "hysteria" -> endpoint.put("version", 2)
            else -> JSONObject().put("servers", JSONArray().put(endpoint))
        }
        val stream = JSONObject().put("network", if (protocol == "hysteria") "hysteria" else "tcp")
            .put("security", if (protocol == "shadowsocks") "none" else "tls")
        if (protocol == "hysteria") stream.put("hysteriaSettings", JSONObject().put("version", 2).put("auth", "fixture-password"))
        return JSONObject().put("log", JSONObject().put("loglevel", "none"))
            .put("dns", JSONObject().put("queryStrategy", "UseIPv4"))
            .put("inbounds", JSONArray().put(JSONObject().put("tag", "tun").put("protocol", "tun")
                .put("settings", JSONObject().put("MTU", 1420))))
            .put("outbounds", JSONArray()
                .put(JSONObject().put("tag", "proxy").put("protocol", protocol).put("settings", settings).put("streamSettings", stream))
                .put(JSONObject().put("tag", "direct").put("protocol", "freedom"))
                .put(JSONObject().put("tag", "block").put("protocol", "blackhole"))
                .put(JSONObject().put("tag", "dns-out").put("protocol", "dns")))
            .put("routing", JSONObject().put("rules", JSONArray()))
    }

    @Test fun tileAcceptsEverySupportedOutboundShape() {
        for (protocol in listOf("vless", "vmess", "trojan", "shadowsocks", "hysteria")) {
            QuickTileProfile.validateConfig(config(protocol).toString(), 1420)
        }
    }

    @Test fun tileRefusesUnknownProtocolAndTlsBypass() {
        val unsupported = config("trojan")
        unsupported.getJSONArray("outbounds").getJSONObject(0).put("protocol", "socks")
        expectRejected(unsupported)
        val bypass = config("hysteria")
        bypass.getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings")
            .put("tlsSettings", JSONObject().put("allowInsecure", true))
        expectRejected(bypass)
    }

    @Test fun tileRequiresHysteria2TlsVersionAndAuthentication() {
        for (case in listOf("no-tls", "version", "auth")) {
            val value = config("hysteria")
            val stream = value.getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings")
            when (case) {
                "no-tls" -> stream.put("security", "none")
                "version" -> stream.getJSONObject("hysteriaSettings").put("version", 1)
                "auth" -> stream.getJSONObject("hysteriaSettings").put("auth", "")
            }
            expectRejected(value)
        }
    }

    private fun expectRejected(value: JSONObject) {
        try {
            QuickTileProfile.validateConfig(value.toString(), 1420)
            fail("Invalid configuration was accepted for the quick tile")
        } catch (expected: QuickTileException) {
            org.junit.Assert.assertEquals("profile_invalid", expected.code)
        }
    }
}
