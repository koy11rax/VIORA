package dev.viora.viora_client

import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

/** Commands originate only from the protected TileService, never exported activity extras. */
internal object TileActionQueue {
    private var connectAt: Long? = null
    fun connect() { connectAt = SystemClock.elapsedRealtime() }
    fun take(): String? {
        val created = connectAt ?: return null
        connectAt = null
        return if (SystemClock.elapsedRealtime() - created in 0..30_000) "connect" else null
    }
    fun clear() { connectAt = null }
}

class QuickSettingsBridge(
    private val activity: MainActivity,
    private val channel: MethodChannel
) {
    private val probe = TunnelStatusProbe(activity)
    private var addResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAddTile" -> addTile(result)
                "takeAction" -> result.success(TileActionQueue.take())
                "snapshot" -> probe.query { state ->
                    if (state == null) result.error("status_unavailable", "Не удалось проверить VPN", null)
                    else result.success(state)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun resumed() { channel.invokeMethod("actionAvailable", null) }

    private fun addTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) { result.success("manual"); return }
        if (!activity.quickSettingsResumed) {
            result.error("not_foreground", "Открой VIORA и повтори", null)
            return
        }
        if (addResult != null) {
            result.error("busy", "Дождись ответа Android", null)
            return
        }
        val manager = activity.getSystemService(StatusBarManager::class.java)
        if (manager == null) { result.success("unavailable"); return }
        addResult = result
        try {
            manager.requestAddTileService(
                ComponentName(activity, VioraTileService::class.java),
                "VIORA VPN", Icon.createWithResource(activity, R.drawable.ic_vpn_notification),
                activity.mainExecutor
            ) { code ->
                val pending = addResult ?: return@requestAddTileService
                addResult = null
                when (code) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> pending.success("added")
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> pending.success("already_added")
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> pending.success("not_added")
                    StatusBarManager.TILE_ADD_REQUEST_ERROR_APP_NOT_IN_FOREGROUND ->
                        pending.error("not_foreground", "Открой VIORA и повтори", null)
                    StatusBarManager.TILE_ADD_REQUEST_ERROR_REQUEST_IN_PROGRESS ->
                        pending.error("busy", "Дождись ответа Android", null)
                    else -> pending.success("unavailable")
                }
            }
        } catch (_: Exception) {
            addResult = null
            result.success("unavailable")
        }
    }

    fun close() {
        addResult?.error("unavailable", "Открой VIORA и повтори", null)
        addResult = null
        probe.close()
        channel.setMethodCallHandler(null)
    }
}
