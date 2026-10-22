package dev.viora.viora_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.core.content.ContextCompat
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayVPNService
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs

class VioraTileService : TileService() {
    private var probe: TunnelStatusProbe? = null
    private var listening = false
    private var clicking = false
    private var generation = 0
    private var destroyed = false
    private var startingUntil = 0L
    private val worker = QuickTileProfile.worker
    private val handler = Handler(Looper.getMainLooper())
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
        if (state == "CONNECTED" || state == "CONNECTING" || state == "FAILED") startingUntil = 0
        val starting = SystemClock.elapsedRealtime() < startingUntil
        tile.label = "VIORA VPN"
        tile.state = if (starting) Tile.STATE_UNAVAILABLE else when (state) {
            "CONNECTED" -> Tile.STATE_ACTIVE
            "DISCONNECTED", "FAILED" -> Tile.STATE_INACTIVE
            else -> Tile.STATE_UNAVAILABLE
        }
        val description = if (starting) "Запуск VPN…" else when (state) {
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
        if (clicking || SystemClock.elapsedRealtime() < startingUntil) return
        unlockAndRun {
            if (clicking) return@unlockAndRun
            clicking = true
            statusProbe().query { state ->
                if (!listening) { clicking = false; return@query }
                when (state) {
                    "CONNECTED" -> {
                        clicking = false
                        // Explicit STOP needs no saved profile or running Flutter engine.
                        try {
                            startService(Intent(this, V2rayVPNService::class.java).putExtra(
                                "COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE
                            ))
                        } catch (_: Exception) { message("Не удалось отключить VPN. Открой VIORA.") }
                    }
                    "DISCONNECTED", "FAILED" -> startInBackground()
                    else -> { clicking = false; message("Не удалось проверить VPN. Повтори нажатие.") }
                }
            }
        }
    }

    private fun startInBackground() {
        startingUntil = SystemClock.elapsedRealtime() + 15_000
        render("DISCONNECTED")
        handler.postDelayed({ if (listening) refresh() }, 15_000)
        worker.execute {
            val failure = try { QuickTileProfile(this).start(); null }
            catch (error: QuickTileException) { error.code }
            catch (_: Exception) { "start_refused" }
            handler.post {
                clicking = false
                if (destroyed) return@post
                if (failure != null) {
                    startingUntil = 0
                    message(when (failure) {
                        "permission_required" -> "Сначала разреши VPN-подключение в VIORA."
                        "profile_unavailable", "profile_invalid" -> "Открой VIORA и выбери рабочий сервер для плитки."
                        else -> "Не удалось запустить VPN. Проверь подключение в VIORA."
                    })
                }
                if (listening) refresh()
            }
        }
    }

    private fun message(text: String) { Toast.makeText(this, text, Toast.LENGTH_LONG).show() }

    override fun onStopListening() {
        generation++
        if (listening) { unregisterReceiver(changes); listening = false }
        probe?.close()
        probe = null
        super.onStopListening()
    }

    override fun onDestroy() {
        destroyed = true
        if (listening) { unregisterReceiver(changes); listening = false }
        probe?.close()
        probe = null
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
