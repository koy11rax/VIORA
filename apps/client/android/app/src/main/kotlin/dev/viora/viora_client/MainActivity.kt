package dev.viora.viora_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var quickSettings: QuickSettingsBridge? = null
    var quickSettingsResumed = false
        private set

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        quickSettings = QuickSettingsBridge(this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.viora/quick_settings"))
        val vault = SecureVault(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.viora/platform")
            .setMethodCallHandler { call, result ->
                if (call.method == "openVpnSettings") {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS))
                        result.success(null)
                    } catch (_: Exception) { result.error("settings_unavailable", "Открой настройки VPN в Android", null) }
                    return@setMethodCallHandler
                }
                if (call.method == "openTelegram") {
                    try {
                        val url = call.argument<String>("url") ?: throw IllegalArgumentException()
                        require(url.length <= 512)
                        val uri = Uri.parse(url)
                        require(uri.scheme == "https" && uri.host == "t.me" && (uri.port == -1 || uri.port == 443))
                        require(uri.userInfo == null && uri.fragment == null)
                        require(Regex("^/[A-Za-z][A-Za-z0-9_]{4,31}$").matches(uri.path ?: ""))
                        if (uri.query != null) {
                            require(uri.queryParameterNames == setOf("start"))
                            require(uri.getQueryParameters("start").size == 1)
                            require(Regex("^viora_[A-Za-z0-9_-]{24}$").matches(uri.getQueryParameter("start") ?: ""))
                        }
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("telegram_unavailable", "Не удалось открыть Telegram. Скопируй ссылку входа.", null)
                    }
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val response: Any? = when (call.method) {
                            "preferencesDirectory" -> applicationContext.filesDir.absolutePath
                            "installationId" -> vault.installationId()
                            "readSession" -> vault.read("session")
                            "saveSession" -> {
                                val value = call.argument<String>("value")
                                    ?: throw IllegalArgumentException()
                                require(value.length <= 16384)
                                vault.save("session", value)
                                null
                            }
                            "clearSession" -> { vault.remove("session"); null }
                            "readProfiles" -> vault.read("profiles")
                            "saveProfiles" -> {
                                val value = call.argument<String>("value") ?: throw IllegalArgumentException()
                                require(value.length <= 1048576)
                                vault.save("profiles", value)
                                null
                            }
                            "applications" -> {
                                val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                                @Suppress("DEPRECATION")
                                val entries = packageManager.queryIntentActivities(query, PackageManager.MATCH_ALL)
                                entries.filter { it.activityInfo.packageName != packageName }
                                    .distinctBy { it.activityInfo.packageName }
                                    .map { mapOf("id" to it.activityInfo.packageName, "name" to it.loadLabel(packageManager).toString()) }
                                    .sortedBy { it["name"] }
                            }
                            else -> { runOnUiThread { result.notImplemented() }; return@execute }
                        }
                        runOnUiThread { result.success(response) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("platform_unavailable", "Не удалось выполнить защищённую операцию", null) }
                    }
                }
            }
    }

    override fun onResume() {
        super.onResume()
        quickSettingsResumed = true
        quickSettings?.resumed()
    }

    override fun onPause() {
        quickSettingsResumed = false
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        quickSettings?.resumed()
    }

    override fun onDestroy() {
        quickSettings?.close()
        quickSettings = null
        worker.shutdown()
        super.onDestroy()
    }
}
