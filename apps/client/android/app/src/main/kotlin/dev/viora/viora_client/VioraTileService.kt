package dev.viora.viora_client

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayVPNService
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs

class VioraTileService : TileService() {
    private var probe: TunnelStatusProbe? = null
    private var listening = false
    private var clicking = false
    private var generation = 0
    private val changes = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { refresh() }
    }

    override fun onStartListening() {
        super.onStartListening()
        if (!listening) {
            ContextCompat.registerReceiver(
                this, changes, IntentFilter(packageName + ".V2RAY_CONNECTION_INFO"),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            listening = true
        }
        refresh()
    }

    private fun statusProbe(): TunnelStatusProbe = probe ?: TunnelStatusProbe(this).also { probe = it }

    private fun refresh() {
        val request = ++generation
        statusProbe().query { state ->
            if (listening && request == generation) render(state)
        }
    }

    private fun render(state: String?) {
        val tile = qsTile ?: return
        tile.label = "VIORA VPN"
        tile.state = when (state) {
            "CONNECTED" -> Tile.STATE_ACTIVE
            "DISCONNECTED", "FAILED" -> Tile.STATE_INACTIVE
            else -> Tile.STATE_UNAVAILABLE
        }
        val description = when (state) {
            "CONNECTED" -> "Подключено"
            "CONNECTING" -> "Подключение…"
            "DISCONNECTED" -> "Отключено"
            "FAILED" -> "Повторить подключение"
            else -> "Открой VIORA"
        }
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = description
        tile.contentDescription = "VIORA VPN · $description"
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (clicking) return
        unlockAndRun {
            if (clicking) return@unlockAndRun
            clicking = true
            statusProbe().query { state ->
                clicking = false
                if (!listening) return@query
                when (state) {
                    "CONNECTED" -> {
                        TileActionQueue.clear()
                        // Explicit STOP needs no saved profile or running Flutter engine.
                        try {
                            startService(Intent(this, V2rayVPNService::class.java).putExtra(
                                "COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE
                            ))
                        } catch (_: Exception) { openApp() }
                    }
                    "DISCONNECTED", "FAILED" -> { TileActionQueue.connect(); openApp() }
                    else -> openApp()
                }
            }
        }
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        )
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(
                    this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                ))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (_: Exception) { TileActionQueue.clear() }
    }

    override fun onStopListening() {
        generation++
        if (listening) { unregisterReceiver(changes); listening = false }
        probe?.close()
        probe = null
        super.onStopListening()
    }

    override fun onDestroy() {
        if (listening) { unregisterReceiver(changes); listening = false }
        probe?.close()
        probe = null
        super.onDestroy()
    }
}
