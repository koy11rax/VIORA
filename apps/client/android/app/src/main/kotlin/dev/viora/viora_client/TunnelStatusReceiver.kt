package dev.viora.viora_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs
import java.util.UUID

/** Read-only IPC into the VPN process. Never starts a tunnel or exposes a config. */
class TunnelStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val nonce = intent.getStringExtra("nonce") ?: return
        if (nonce.length != 36) return
        val state = try {
            val manager = V2rayCoreManager.getInstance()
            when (manager.V2RAY_STATE) {
                AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ->
                    if (manager.isV2rayCoreRunning) "CONNECTED" else "DISCONNECTED"
                AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                AppConfigs.V2RAY_STATES.V2RAY_FAILED -> "FAILED"
                else -> "DISCONNECTED"
            }
        } catch (_: Exception) { "UNKNOWN" }
        context.sendBroadcast(
            Intent(context.packageName + STATUS_ACTION).setPackage(context.packageName)
                .putExtra("nonce", nonce).putExtra("state", state)
        )
    }

    companion object {
        const val STATUS_ACTION = ".QUICK_SETTINGS_STATUS"
    }
}

/** Every query has a deadline and an unexported response receiver, including API 26–32. */
class TunnelStatusProbe(context: Context) {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val pending = mutableMapOf<String, (String?) -> Unit>()
    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val nonce = intent.getStringExtra("nonce") ?: return
            val state = intent.getStringExtra("state")
            if (state !in setOf("CONNECTED", "CONNECTING", "DISCONNECTED", "FAILED", "UNKNOWN")) return
            pending.remove(nonce)?.invoke(if (state == "UNKNOWN") null else state)
        }
    }

    fun query(callback: (String?) -> Unit) {
        try {
            if (!registered) {
                ContextCompat.registerReceiver(
                    context, receiver,
                    IntentFilter(context.packageName + TunnelStatusReceiver.STATUS_ACTION),
                    ContextCompat.RECEIVER_NOT_EXPORTED
                )
                registered = true
            }
            val nonce = UUID.randomUUID().toString()
            pending[nonce] = callback
            handler.postDelayed({ pending.remove(nonce)?.invoke(null) }, 2_000)
            context.sendBroadcast(
                Intent(context, TunnelStatusReceiver::class.java).putExtra("nonce", nonce)
            )
        } catch (_: Exception) {
            // Do not infer "disconnected" when the daemon could not be queried.
            val callbacks = pending.values.toList()
            pending.clear()
            if (callbacks.isEmpty()) callback(null) else callbacks.forEach { it(null) }
        }
    }

    fun close() {
        handler.removeCallbacksAndMessages(null)
        if (registered) context.unregisterReceiver(receiver)
        registered = false
        val callbacks = pending.values.toList()
        pending.clear()
        callbacks.forEach { it(null) }
    }
}
