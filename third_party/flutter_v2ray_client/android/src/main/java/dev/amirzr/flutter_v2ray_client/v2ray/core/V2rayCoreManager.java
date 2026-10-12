package dev.amirzr.flutter_v2ray_client.v2ray.core;

import static dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities.getUserAssetsPath;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.CountDownTimer;
import android.os.SystemClock;
import java.util.Locale;
import android.util.Log;
import android.util.Pair;

import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;

import dev.amirzr.flutter_v2ray_client.v2ray.interfaces.V2rayServicesListener;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayProxyOnlyService;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayVPNService;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.V2rayConfig;

import org.json.JSONObject;

import libv2ray.CoreCallbackHandler;
import libv2ray.CoreController;
import libv2ray.Libv2ray;
import libv2ray.V2RayProtector;

public final class V2rayCoreManager {
    private static final int NOTIFICATION_ID = 1;
    private volatile static V2rayCoreManager INSTANCE;
    public V2rayServicesListener v2rayServicesListener = null;
    private Context serviceContext;
    private CoreController coreController;
    public AppConfigs.V2RAY_STATES V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
    private boolean isLibV2rayCoreInitialized = false;
    private CountDownTimer countDownTimer;
    private long connectedAt, sampledAt;
    private volatile boolean restarting;
    private NotificationCompat.Builder notificationBuilder;
    private long totalDownload, totalUpload, uploadSpeed, downloadSpeed;
    private String SERVICE_DURATION = "00:00:00";

    public static V2rayCoreManager getInstance() {
        if (INSTANCE == null) {
            synchronized (V2rayCoreManager.class) {
                if (INSTANCE == null) {
                    INSTANCE = new V2rayCoreManager();
                }
            }
        }
        return INSTANCE;
    }

    private void makeDurationTimer(final Context context, final boolean enable_traffic_statics) {
        countDownTimer = new CountDownTimer(86_400_000L, 1000) {
            @RequiresApi(api = Build.VERSION_CODES.M)
            public void onTick(long millisUntilFinished) {

                long now = SystemClock.elapsedRealtime();
                long elapsed = (now - connectedAt) / 1000;
                if (enable_traffic_statics) {
                    long[] delta = queryOutboundTrafficDelta();
                    long interval = Math.max(1, now - sampledAt);
                    downloadSpeed = delta[0] * 1000 / interval;
                    uploadSpeed = delta[1] * 1000 / interval;
                    totalDownload += delta[0];
                    totalUpload += delta[1];
                }
                sampledAt = now;
                SERVICE_DURATION = String.format(Locale.ROOT, "%02d:%02d:%02d",
                        elapsed / 3600, elapsed / 60 % 60, elapsed % 60);
                updateNotification(context);
                String packageName = context.getPackageName();
                Intent connection_info_intent = new Intent(packageName + ".V2RAY_CONNECTION_INFO");
                connection_info_intent.setPackage(packageName);
                connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
                if (Build.VERSION.SDK_INT >= 29 && v2rayServicesListener != null && v2rayServicesListener.getService() instanceof V2rayVPNService) {
                    V2rayVPNService vpn = (V2rayVPNService) v2rayServicesListener.getService();
                    connection_info_intent.putExtra("ALWAYS_ON", vpn.isAlwaysOn());
                    connection_info_intent.putExtra("LOCKDOWN", vpn.isLockdownEnabled());
                }
                connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
                connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
                connection_info_intent.putExtra("DOWNLOAD_SPEED", downloadSpeed);
                connection_info_intent.putExtra("UPLOAD_TRAFFIC", totalUpload);
                connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload);
                try {
                    context.sendBroadcast(connection_info_intent);
                } catch (Exception e) {
                    Log.w("V2rayCoreManager", "Failed to send connection info broadcast", e);
                }
            }

            public void onFinish() {
                countDownTimer.cancel();
                if (V2rayCoreManager.getInstance().isV2rayCoreRunning())
                    makeDurationTimer(context, enable_traffic_statics);
            }
        }.start();
    }

    /**
     * Parses {@link CoreController#queryAllOutboundTrafficStats()} output.
     * Format: tag,direction,value;tag,direction,value;
     * Counts only actual proxy traffic; blocked traffic is not transferred.
     *
     * @return long[2] = {downloadDelta, uploadDelta}
     */
    private long[] queryOutboundTrafficDelta() {
        long download = 0;
        long upload = 0;
        if (coreController == null) {
            return new long[] { 0, 0 };
        }
        String stats = coreController.queryAllOutboundTrafficStats();
        if (stats == null || stats.isEmpty()) {
            return new long[] { 0, 0 };
        }
        String[] entries = stats.split(";");
        for (String entry : entries) {
            if (entry == null || entry.isEmpty()) {
                continue;
            }
            String[] parts = entry.split(",");
            if (parts.length != 3) {
                continue;
            }
            String tag = parts[0];
            if (!"proxy".equals(tag)) {
                continue;
            }
            long value;
            try {
                value = Long.parseLong(parts[2]);
            } catch (NumberFormatException e) {
                continue;
            }
            if ("downlink".equals(parts[1])) {
                download += value;
            } else if ("uplink".equals(parts[1])) {
                upload += value;
            }
        }
        return new long[] { download, upload };
    }

    public void setUpListener(Service targetService) {
        try {
            v2rayServicesListener = (V2rayServicesListener) targetService;
            serviceContext = targetService.getApplicationContext();
            Libv2ray.initCoreEnv(getUserAssetsPath(targetService.getApplicationContext()), "");

            // Register Android VPN socket protector with libv2ray (Go)
            Libv2ray.useProtector(new V2RayProtector() {
                @Override
                public boolean protect(long fd) {
                    if (v2rayServicesListener != null) {
                        return v2rayServicesListener.onProtect((int) fd);
                    }
                    return true;
                }
            });
            // Initialize controller with callback handler
            coreController = Libv2ray.newCoreController(new CoreCallbackHandler() {
                @Override
                public long onEmitStatus(long p0, String p1) {
                    // Currently unused; log for debugging
                    // Do not expose native status payloads (may include server/profile details).
                    return 0;
                }

                @Override
                public long shutdown() {
                    if (restarting) return 0;
                    if (v2rayServicesListener == null) {
                        Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed => can`t find initial service.");
                        return -1;
                    }
                    try {
                        v2rayServicesListener.stopService();
                        return 0;
                    } catch (Exception e) {
                        Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed =>", e);
                        return -1;
                    }
                }

                @Override
                public long startup() {
                    if (v2rayServicesListener != null) {
                        try {
                            v2rayServicesListener.startService();
                        } catch (Exception e) {
                            Log.e(V2rayCoreManager.class.getSimpleName(), "startup failed => ", e);
                            return -1;
                        }
                    }
                    return 0;
                }
            });
            isLibV2rayCoreInitialized = true;
            SERVICE_DURATION = "00:00:00";
        connectedAt = sampledAt = 0;
            uploadSpeed = 0;
            downloadSpeed = 0;
            totalDownload = 0;
            totalUpload = 0;
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener => new initialize from "
                    + v2rayServicesListener.getService().getClass().getSimpleName());
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener failed => ", e);
            isLibV2rayCoreInitialized = false;
        }
    }

    public boolean startCore(final V2rayConfig v2rayConfig) {
        return startCore(v2rayConfig, 0);
    }

    /**
     * @param tunFd VpnService TUN file descriptor for native Xray TUN inbound.
     *              Pass 0 for proxy-only mode.
     */
    public boolean startCore(final V2rayConfig v2rayConfig, int tunFd) {
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING;
        if (!isLibV2rayCoreInitialized) {
            Log.e(V2rayCoreManager.class.getSimpleName(),
                    "startCore failed => LibV2rayCore should be initialize before start.");
            return false;
        }
        if (isV2rayCoreRunning()) {
            stopCore();
        }
        try {
            if (coreController == null) {
                Log.e(V2rayCoreManager.class.getSimpleName(), "startCore failed => coreController is null.");
                return false;
            }
            // The source-built bridge protects every outbound socket through
            // VpnService.protect; no separate server-specific bypass is needed.
            String config = Utilities.stripRemovedTlsOptions(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            if (tunFd > 0) {
                config = Utilities.ensureTunInbound(config, v2rayConfig.MTU);
            }
            Log.i(V2rayCoreManager.class.getSimpleName(),
                    "startCore => tunFd=" + tunFd);
            coreController.startLoop(config, tunFd);
            if (!isV2rayCoreRunning()) {
                throw new IllegalStateException("Core did not start");
            }
            V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED;
            if (isV2rayCoreRunning()) {
                connectedAt = sampledAt = SystemClock.elapsedRealtime();
                totalDownload = totalUpload = downloadSpeed = uploadSpeed = 0;
                SERVICE_DURATION = "00:00:00";
                showNotification(v2rayConfig);
                makeDurationTimer(v2rayServicesListener.getService().getApplicationContext(),
                        v2rayConfig.ENABLE_TRAFFIC_STATICS);
            }
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "Unable to start native core");
            return false;
        }
        return true;
    }

    public void stopCore() {
        // Native stopLoop can invoke shutdown() synchronously.
        // Retain the service/context until the actual stop acknowledgement is sent.
        final V2rayServicesListener stoppingListener = v2rayServicesListener;
        final Context stoppingContext = serviceContext;
        if (countDownTimer != null) countDownTimer.cancel();
        notificationBuilder = null;
        try {
            // Safely cancel notification - handle cases where service might be null
            if (v2rayServicesListener != null && v2rayServicesListener.getService() != null) {
                NotificationManager notificationManager = (NotificationManager) v2rayServicesListener.getService()
                        .getSystemService(Context.NOTIFICATION_SERVICE);
                if (notificationManager != null) {
                    notificationManager.cancel(NOTIFICATION_ID);
                }
            }
        } catch (Exception e) {
            Log.w("V2rayCoreManager", "Failed to cancel notification", e);
        }

        try {
            if (isV2rayCoreRunning()) {
                if (coreController != null) {
                    coreController.stopLoop();
                }
                if (isV2rayCoreRunning()) {
                    Log.w("V2rayCoreManager", "Native core has not confirmed stop");
                    return;
                }
                if (!restarting && stoppingListener != null) stoppingListener.stopService();
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore success => v2ray core stopped.");
            } else {
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed => v2ray core not running.");
            }
            if (!restarting) sendDisconnectedBroadCast(stoppingContext);
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed =>", e);
        }
    }

    public void stopForRestart() {
        restarting = true;
        try { stopCore(); } finally { restarting = false; }
    }

    public void showStartingNotification(V2rayConfig config) {
        showNotification(config);
        if (notificationBuilder != null) {
            notificationBuilder.setContentTitle("Viora VPN · подключаемся")
                .setContentText("Восстанавливаем защищённое соединение");
            v2rayServicesListener.getService().startForeground(NOTIFICATION_ID, notificationBuilder.build());
        }
    }

    private void sendDisconnectedBroadCast(Context context) {
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
        SERVICE_DURATION = "00:00:00";
        connectedAt = sampledAt = 0;
        uploadSpeed = 0;
        downloadSpeed = 0;
        if (context != null) {
            String packageName = context.getPackageName();
            Intent connection_info_intent = new Intent(packageName + ".V2RAY_CONNECTION_INFO");
            connection_info_intent.setPackage(packageName);
            connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
            connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
            connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
            connection_info_intent.putExtra("DOWNLOAD_SPEED", downloadSpeed);
            connection_info_intent.putExtra("UPLOAD_TRAFFIC", totalUpload);
            connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload);
            try {
                context.sendBroadcast(connection_info_intent);
            } catch (Exception e) {
                Log.w("V2rayCoreManager", "Failed to send disconnected broadcast", e);
            }
        }
        if (countDownTimer != null) {
            countDownTimer.cancel();
        }
    }

    private String createNotificationChannelID(String appName) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            String channelId = "viora_vpn_status_v3";
            try {
                if (v2rayServicesListener == null || v2rayServicesListener.getService() == null) {
                    return channelId;
                }

                NotificationManager notificationManager = (NotificationManager) v2rayServicesListener.getService()
                        .getSystemService(Context.NOTIFICATION_SERVICE);

                String channelName = "Подключение Viora VPN";
                NotificationChannel channel = new NotificationChannel(channelId, channelName,
                        NotificationManager.IMPORTANCE_DEFAULT);
                channel.setSound(null, null);
                channel.enableVibration(false);
                channel.setDescription(channelName);
                channel.setLightColor(Color.DKGRAY);
                channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);

                if (notificationManager != null) {
                    notificationManager.createNotificationChannel(channel);
                }
            } catch (Exception e) {
                Log.w("V2rayCoreManager", "Failed to create notification channel", e);
            }

            return channelId;
        }
        return "";
    }

    private void showNotification(final V2rayConfig v2rayConfig) {
        Service context = v2rayServicesListener.getService();
        if (context == null) {
            return;
        }

        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launchIntent != null) {
            launchIntent.setAction(Intent.ACTION_MAIN);
            launchIntent.setFlags(
                    Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_NEW_TASK);
        }
        final int flags;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        } else {
            flags = PendingIntent.FLAG_UPDATE_CURRENT;
        }
        PendingIntent notificationContentPendingIntent = PendingIntent.getActivity(
                context, 0, launchIntent, flags);

        String notificationChannelID = createNotificationChannelID(v2rayConfig.APPLICATION_NAME);

        Intent stopIntent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            stopIntent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            stopIntent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);

        PendingIntent pendingIntent = PendingIntent.getService(
                context, 0, stopIntent, flags);

        try {
            // Build the notification
            notificationBuilder = new NotificationCompat.Builder(context,
                    notificationChannelID)
                    .setSmallIcon(dev.amirzr.flutter_v2ray_client.R.drawable.ic_viora_vpn)
                    .setContentTitle("Viora VPN · подключено")
                    .setContentText("00:00:00 · ↓ 0 КБ/с · ↑ 0 КБ/с")
                    .addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, pendingIntent)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .setShowWhen(false)
                    .setOnlyAlertOnce(true)
                    .setContentIntent(notificationContentPendingIntent)
                    .setOngoing(true);

            context.startForeground(NOTIFICATION_ID, notificationBuilder.build());
        } catch (Exception e) {
            Log.w("V2rayCoreManager", "Failed to show notification, continuing without notification", e);
            // VPN/Proxy continues to work even if notification fails
        }
    }

    private void updateNotification(Context context) {
        if (notificationBuilder == null || V2RAY_STATE != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) return;
        String speeds = String.format(Locale.ROOT, "↓ %.1f КБ/с · ↑ %.1f КБ/с", downloadSpeed / 1024.0, uploadSpeed / 1024.0);
        String totals = String.format(Locale.ROOT, "Получено %.1f МБ · отправлено %.1f МБ\nВсего %.1f МБ", totalDownload / 1048576.0, totalUpload / 1048576.0, (totalDownload + totalUpload) / 1048576.0);
        notificationBuilder.setContentText(SERVICE_DURATION + " · " + speeds)
            .setSubText(String.format(Locale.ROOT, "Всего %.1f МБ", (totalDownload + totalUpload) / 1048576.0))
            .setStyle(new NotificationCompat.BigTextStyle().bigText("Подключено " + SERVICE_DURATION + "\n" + speeds + "\n" + totals));
        if (Build.VERSION.SDK_INT >= 33 && ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        try {
            if (manager != null) manager.notify(NOTIFICATION_ID, notificationBuilder.build());
        } catch (RuntimeException error) {
            Log.w("V2rayCoreManager", "Unable to update VPN notification");
        }
    }
    public boolean isV2rayCoreRunning() {
        if (coreController != null) {
            return coreController.getIsRunning();
        }
        return false;
    }

    public Long getConnectedV2rayServerDelay() {
        try {
            if (coreController == null)
                return -1L;
            return coreController.measureDelay(AppConfigs.DELAY_URL);
        } catch (Exception e) {
            return -1L;
        }
    }

    public Long getV2rayServerDelay(final String config, final String url) {
        try {
            String sanitized = Utilities.stripRemovedTlsOptions(config);
            try {
                JSONObject config_json = new JSONObject(sanitized);
                JSONObject new_routing_json = config_json.getJSONObject("routing");
                new_routing_json.remove("rules");
                config_json.remove("routing");
                config_json.put("routing", new_routing_json);
                return Libv2ray.measureOutboundDelay(config_json.toString(), url);
            } catch (Exception json_error) {
                Log.e("getV2rayServerDelay", json_error.toString());
                return Libv2ray.measureOutboundDelay(sanitized, url);
            }
        } catch (Exception e) {
            Log.e("getV2rayServerDelayCore", e.toString());
            return -1L;
        }
    }

}
