package dev.viora.viora_client

import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService

class QuickSettingsBridge(
    private val activity: MainActivity,
    private val channel: MethodChannel,
    private val worker: ExecutorService
) {
    private val probe = TunnelStatusProbe(activity)
    private var addResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAddTile" -> addTile(result)
                "prepareProfile" -> worker.execute {
                    try {
                        require(call.arguments == null || call.arguments is Map<*, *>)
                        val saved = QuickTileProfile(activity).save(call.arguments as Map<*, *>?)
                        check(call.arguments == null || saved)
                        activity.runOnUiThread { result.success(null) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.error("profile_unavailable", "Не удалось подготовить плитку", null) }
                    }
                }
                "snapshot" -> probe.query { state ->
                    if (state == null) result.error("status_unavailable", "Не удалось проверить VPN", null)
                    else result.success(state)
                }
                else -> result.notImplemented()
            }
        }
    }

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
