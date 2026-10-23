package dev.amirzr.flutter_v2ray_client.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import androidx.core.content.ContextCompat;

import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayProxyOnlyService;
import dev.amirzr.flutter_v2ray_client.v2ray.services.V2rayVPNService;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities;

import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import libv2ray.Libv2ray;

public class V2rayController {

    public static void init(final Context context, final int app_icon, final String app_name) {
        Utilities.copyAssets(context);
        AppConfigs.APPLICATION_ICON = app_icon;
        AppConfigs.APPLICATION_NAME = app_name;

        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                if (arg1 == null) return;
                try {
                    Object state = arg1.getSerializableExtra("STATE");
                    if (state instanceof AppConfigs.V2RAY_STATES) {
                        AppConfigs.V2RAY_STATE = (AppConfigs.V2RAY_STATES) state;
                    }
                } catch (RuntimeException ignored) {
                    // Malformed status must not crash the UI or alter its state.
                }
            }
        };
        // The private receiver also authenticates same-app senders on API < 33.
        String packageName = context.getPackageName();
        IntentFilter filter = new IntentFilter(packageName + ".V2RAY_CONNECTION_INFO");
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    public static void changeConnectionMode(final AppConfigs.V2RAY_CONNECTION_MODES connection_mode) {
        if (getConnectionState() == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            AppConfigs.V2RAY_CONNECTION_MODE = connection_mode;
        }
    }

    public static void StartV2ray(final Context context, final String remark, final String config,
            final ArrayList<String> blocked_apps, final ArrayList<String> bypass_subnets,
            final ArrayList<String> allowed_apps, final int mtu,
            final boolean reconnect, final boolean strict, final int retries) {
        StartV2ray(context, remark, config, blocked_apps, bypass_subnets,
                allowed_apps, mtu, reconnect, strict, retries, false);
    }

    public static void StartV2ray(final Context context, final String remark, final String config,
            final ArrayList<String> blocked_apps, final ArrayList<String> bypass_subnets,
            final ArrayList<String> allowed_apps, final int mtu,
            final boolean reconnect, final boolean strict, final int retries, final boolean fromQuickTile) {
        AppConfigs.V2RAY_CONFIG = Utilities.parseV2rayJsonFile(remark, config, blocked_apps, bypass_subnets);
        if (AppConfigs.V2RAY_CONFIG == null) {
            throw new IllegalArgumentException("Invalid VPN configuration");
        }
        if (mtu < 1280 || mtu > 1500) throw new IllegalArgumentException("Invalid MTU");
        if (allowed_apps != null && allowed_apps.isEmpty()) throw new IllegalArgumentException("No selected apps");
        if (allowed_apps != null && blocked_apps != null && !blocked_apps.isEmpty()) throw new IllegalArgumentException("Conflicting app modes");
        AppConfigs.V2RAY_CONFIG.ALLOWED_APPS = allowed_apps;
        AppConfigs.V2RAY_CONFIG.MTU = mtu;
        if (retries < 1 || retries > 5) throw new IllegalArgumentException("Invalid retries");
        AppConfigs.V2RAY_CONFIG.RECONNECT = reconnect;
        AppConfigs.V2RAY_CONFIG.REQUIRE_LOCKDOWN = strict;
        AppConfigs.V2RAY_CONFIG.RETRIES = retries;
        Intent start_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            start_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            start_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        start_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE);
        start_intent.putExtra("V2RAY_CONFIG", AppConfigs.V2RAY_CONFIG);
        start_intent.putExtra("FROM_QUICK_TILE", fromQuickTile);
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.N_MR1) {
            context.startForegroundService(start_intent);
        } else {
            context.startService(start_intent);
        }
    }

    public static void StopV2ray(final Context context) {
        Intent stop_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            stop_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            stop_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        stop_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);
        context.startService(stop_intent);
        AppConfigs.V2RAY_CONFIG = null;
    }

    public static long getConnectedV2rayServerDelay(Context context) {
        return getConnectedV2rayServerDelay(context, AppConfigs.DELAY_URL);
    }

    public static long getConnectedV2rayServerDelay(Context context, final String url) {
        if (!V2rayCoreManager.isSafeDelayUrl(url)) return -1;
        if (V2rayController.getConnectionState() != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
            return -1;
        }
        Intent check_delay;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            check_delay = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            check_delay = new Intent(context, V2rayVPNService.class);
        } else {
            return -1;
        }
        final long[] delay = { -1 };
        final String requestId = UUID.randomUUID().toString();
        final CountDownLatch latch = new CountDownLatch(1);
        check_delay.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY);
        check_delay.putExtra("DELAY_URL", url);
        check_delay.putExtra("REQUEST_ID", requestId);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                if (arg1 == null || !requestId.equals(arg1.getStringExtra("REQUEST_ID"))) return;
                try {
                    delay[0] = Long.parseLong(arg1.getStringExtra("DELAY"));
                    latch.countDown();
                } catch (RuntimeException ignored) { /* Wait for a matching well-formed result. */ }
            }
        };

        // Use package-specific intent filter to isolate broadcasts per app
        String packageName = context.getPackageName();
        IntentFilter delayIntentFilter = new IntentFilter(packageName + ".CONNECTED_V2RAY_SERVER_DELAY");
        boolean registered = false;
        try {
            // Register before dispatch: an already warm core can reply immediately.
            ContextCompat.registerReceiver(context, receiver, delayIntentFilter, ContextCompat.RECEIVER_NOT_EXPORTED);
            registered = true;
            context.startService(check_delay);
            // Native MeasureDelay is bounded by 12s; allow the IPC result to arrive.
            boolean received = latch.await(15000, TimeUnit.MILLISECONDS);
            if (!received) {
                return -1;
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return -1;
        } catch (RuntimeException e) {
            return -1;
        } finally {
            if (registered) {
                try { context.unregisterReceiver(receiver); } catch (IllegalArgumentException ignored) { }
            }
        }
        return delay[0];
    }

    public static long getV2rayServerDelay(final String config, final String url) {
        return V2rayCoreManager.getInstance().getV2rayServerDelay(config, url);
    }

    public static AppConfigs.V2RAY_CONNECTION_MODES getConnectionMode() {
        return AppConfigs.V2RAY_CONNECTION_MODE;
    }

    public static AppConfigs.V2RAY_STATES getConnectionState() {
        return AppConfigs.V2RAY_STATE;
    }

    public static String getCoreVersion() {
        return Libv2ray.checkVersionX();
    }

}
