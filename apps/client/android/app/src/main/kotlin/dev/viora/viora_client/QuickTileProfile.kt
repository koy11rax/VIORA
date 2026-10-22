package dev.viora.viora_client

import android.content.Context
import android.net.VpnService
import dev.amirzr.flutter_v2ray_client.v2ray.V2rayController
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class QuickTileException(val code: String) : Exception(code)

/** Latest validated UI configuration, encrypted by the installation's existing vault. */
class QuickTileProfile(context: Context) {
    private val context = context.applicationContext
    private val vault = SecureVault(this.context)

    /** Call on the UI preparation worker; an invalid replacement revokes the old profile. */
    fun save(payload: Map<*, *>?): Boolean = synchronized(lock) {
        invalidated = true
        vault.remove(KEY)
        if (payload == null) return@synchronized false
        val profile = try { parse(payload) } catch (_: QuickTileException) { return@synchronized false }
        ensureAssets(preparing = true)
        vault.save(KEY, profile.encode())
        invalidated = false
        true
    }

    /** Called only after an unlocked tile click, on its worker; never launches an Activity. */
    fun start() = synchronized(lock) {
        if (invalidated) throw QuickTileException("profile_unavailable")
        val saved = try { vault.read(KEY) } catch (_: Exception) {
            invalidate()
            throw QuickTileException("profile_unavailable")
        } ?: throw QuickTileException("profile_unavailable")
        val profile = try { decode(saved) } catch (_: Exception) {
            invalidate()
            throw QuickTileException("profile_invalid")
        }
        if (VpnService.prepare(context) != null) throw QuickTileException("permission_required")
        // No file copying or expensive Flutter startup in the temporary click exemption.
        ensureAssets(preparing = false)
        AppConfigs.APPLICATION_ICON = R.drawable.ic_vpn_notification
        AppConfigs.APPLICATION_NAME = "Viora"
        AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = "Отключить"
        AppConfigs.V2RAY_CONNECTION_MODE = AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN
        try {
            V2rayController.StartV2ray(context, profile.name, profile.config,
                ArrayList(profile.blocked), null, profile.allowed?.let { ArrayList(it) },
                profile.mtu, profile.reconnect, profile.strict, profile.retries)
        } catch (_: Exception) {
            // Includes Android background FGS refusal: never bypass it by opening the UI.
            throw QuickTileException("start_refused")
        }
    }

    private fun invalidate() {
        invalidated = true
        try { vault.remove(KEY) } catch (_: Exception) { /* Stay revoked in this process. */ }
    }

    private fun ensureAssets(preparing: Boolean) {
        try {
            val path = Utilities.getUserAssetsPath(context)
            if (path.isNullOrBlank()) throw QuickTileException("assets_unavailable")
            val directory = File(path)
            if (!directory.isDirectory && (!preparing || !directory.mkdirs())) {
                throw QuickTileException("assets_unavailable")
            }
            // Current configurations do not require geo databases. If shipped later,
            // prepare only those actually bundled with this APK, once when missing.
            val bundled = context.assets.list("").orEmpty().filter { it == "geoip.dat" || it == "geosite.dat" }
            fun ready() = bundled.all { File(directory, it).let { file -> file.isFile && file.canRead() && file.length() > 0 } }
            if (!ready() && preparing) Utilities.copyAssets(context)
            if (!ready()) throw QuickTileException("assets_unavailable")
        } catch (error: QuickTileException) {
            throw error
        } catch (_: Exception) {
            throw QuickTileException("assets_unavailable")
        }
    }

    private data class Profile(val name: String, val config: String, val allowed: List<String>?,
        val blocked: List<String>, val mtu: Int, val reconnect: Boolean, val strict: Boolean, val retries: Int) {
        fun encode(): String = JSONObject().put("version", 1).put("name", name).put("config", config)
            .put("allowed", allowed?.let { JSONArray(it) } ?: JSONObject.NULL).put("blocked", JSONArray(blocked))
            .put("mtu", mtu).put("reconnect", reconnect).put("strict", strict).put("retries", retries).toString()
    }

    companion object {
        // App-scoped FIFO shared by Activity vault operations and unlocked tile starts.
        // Activity/TileService destruction must not shut this executor down.
        val worker = Executors.newSingleThreadExecutor()
        private const val KEY = "quick_tile_profile"
        private val lock = Any()
        private var invalidated = false
        private val fields = setOf("version", "name", "config", "allowed", "blocked", "mtu", "reconnect", "strict", "retries")
        private val packageName = Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$")

        private fun requireProfile(condition: Boolean) {
            if (!condition) throw QuickTileException("profile_invalid")
        }

        private fun apps(value: Any?, nullable: Boolean): List<String>? {
            if (value == null && nullable) return null
            val list = value as? List<*> ?: throw QuickTileException("profile_invalid")
            requireProfile(list.size <= 1000 && (!nullable || list.isNotEmpty()))
            val result = list.map {
                val id = it as? String ?: throw QuickTileException("profile_invalid")
                requireProfile(id.length <= 255 && packageName.matches(id) && id != "dev.viora.viora_client")
                id
            }
            requireProfile(result.distinct().size == result.size)
            return result
        }

        private fun parse(payload: Map<*, *>): Profile {
            requireProfile(payload.keys == fields && payload["version"] == 1)
            val name = payload["name"] as? String ?: throw QuickTileException("profile_invalid")
            val config = payload["config"] as? String ?: throw QuickTileException("profile_invalid")
            requireProfile(name.isNotBlank() && name.length <= 16_384 && name.none { it.isISOControl() })
            requireProfile(config.isNotBlank() && config.length <= 262_144 && config.toByteArray(Charsets.UTF_8).size <= 262_144)
            val allowed = apps(payload["allowed"], nullable = true)
            val blocked = apps(payload["blocked"], nullable = false)!!
            requireProfile(allowed == null || blocked.isEmpty())
            val mtu = payload["mtu"] as? Int ?: throw QuickTileException("profile_invalid")
            val retries = payload["retries"] as? Int ?: throw QuickTileException("profile_invalid")
            val reconnect = payload["reconnect"] as? Boolean ?: throw QuickTileException("profile_invalid")
            val strict = payload["strict"] as? Boolean ?: throw QuickTileException("profile_invalid")
            requireProfile(mtu in setOf(1280, 1420, 1500) && retries in 1..5)
            validateConfig(config, mtu)
            val profile = Profile(name, config, allowed, blocked, mtu, reconnect, strict, retries)
            // Leave room under Binder's transaction limit even for long package lists.
            requireProfile(profile.encode().length <= 400_000)
            return profile
        }

        private fun decode(text: String): Profile {
            requireProfile(text.length <= 400_000)
            val json = JSONObject(text)
            val values = json.keys().asSequence().associateWith { key ->
                when (val value = json.get(key)) {
                    JSONObject.NULL -> null
                    is JSONArray -> (0 until value.length()).map { value.get(it) }
                    else -> value
                }
            }
            return parse(values)
        }

        private fun validateConfig(config: String, mtu: Int) {
            try {
                // Check nesting before JSONObject's recursive parser can consume it.
                var depth = 0
                var quoted = false
                var escaped = false
                for (character in config) {
                    if (quoted) {
                        if (escaped) escaped = false
                        else if (character == '\\') escaped = true
                        else if (character == '"') quoted = false
                    } else when (character) {
                        '"' -> quoted = true
                        '{', '[' -> { depth++; requireProfile(depth <= 24) }
                        '}', ']' -> { depth--; requireProfile(depth >= 0) }
                    }
                }
                requireProfile(!quoted && depth == 0)
                val json = JSONObject(config)
                requireProfile(json.keys().asSequence().toSet() == setOf("log", "dns", "inbounds", "outbounds", "routing"))
                requireProfile(json.getJSONObject("log").optString("loglevel") == "none")
                requireProfile(json.getJSONObject("dns").optString("queryStrategy") == "UseIPv4")
                val inbounds = json.getJSONArray("inbounds")
                requireProfile(inbounds.length() == 1)
                val inbound = inbounds.getJSONObject(0)
                requireProfile(inbound.optString("protocol") == "tun" && inbound.optString("tag") == "tun")
                requireProfile(inbound.getJSONObject("settings").getInt("MTU") == mtu)
                val outbounds = json.getJSONArray("outbounds")
                requireProfile(outbounds.length() == 4)
                for ((index, pair) in listOf("proxy" to "vless", "direct" to "freedom", "block" to "blackhole", "dns-out" to "dns").withIndex()) {
                    val outbound = outbounds.getJSONObject(index)
                    requireProfile(outbound.optString("tag") == pair.first && outbound.optString("protocol") == pair.second)
                }
                val security = outbounds.getJSONObject(0).getJSONObject("streamSettings").optString("security")
                requireProfile(security == "tls" || security == "reality")
                val rules = json.getJSONObject("routing").getJSONArray("rules")
                requireProfile(rules.length() <= 4096)
                // Bound nesting and reject TLS bypass options before any native parser sees it.
                var nodes = 0
                fun visit(value: Any?, depth: Int) {
                    requireProfile(depth <= 24 && ++nodes <= 32_768)
                    when (value) {
                        is JSONObject -> value.keys().forEach { key ->
                            requireProfile(key != "allowInsecure")
                            visit(value.get(key), depth + 1)
                        }
                        is JSONArray -> for (i in 0 until value.length()) visit(value.get(i), depth + 1)
                    }
                }
                visit(json, 0)
                requireProfile(Utilities.parseV2rayJsonFile("VIORA", config, ArrayList(), null) != null)
            } catch (error: QuickTileException) { throw error }
            catch (_: Exception) { throw QuickTileException("profile_invalid") }
        }
    }
}
