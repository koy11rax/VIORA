package dev.amirzr.flutter_v2ray_client.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import org.json.JSONArray;
import org.json.JSONObject;

import dev.amirzr.flutter_v2ray_client.v2ray.core.V2rayCoreManager;
import dev.amirzr.flutter_v2ray_client.v2ray.interfaces.V2rayServicesListener;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.AppConfigs;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.Utilities;
import dev.amirzr.flutter_v2ray_client.v2ray.utils.V2rayConfig;


/**
 * VPN mode using LibXrayLite native TUN ({@code startLoop(config, tunFd)}).
 * <p>
 * Modern AndroidLibXrayLite no longer relies on external tun2socks for the default
 * VPN path. The VpnService FD is passed into Xray's built-in TUN inbound.
 */
public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private static final int VPN_MTU = 1500;

    private ParcelFileDescriptor mInterface;
    private V2rayConfig v2rayConfig;
    private boolean isRunning = false;
    /** True after VPN interface is established and before/while core owns the FD. */
    private boolean vpnInterfaceReady = false;

    @Override
    public void onCreate() {
        super.onCreate();
        V2rayCoreManager.getInstance().setUpListener(this);
    }

    private final android.os.Handler handler = new android.os.Handler(android.os.Looper.getMainLooper());
    private volatile boolean desired, recovering, destroyed;
    private int failures;
    private boolean recoveryScheduled, acknowledgeStop;
    private final Runnable healthCheck = new Runnable() {
        @Override public void run() {
            if (!desired || destroyed) return;
            if (!recovering && !recoveryScheduled && !V2rayCoreManager.getInstance().isV2rayCoreRunning()) scheduleRecovery();
            if (desired) handler.postDelayed(this, 5000);
        }
    };
    private dev.amirzr.flutter_v2ray_client.v2ray.utils.TunnelSessionStore sessionStore;
    private android.net.ConnectivityManager connectivity;
    private android.net.ConnectivityManager.NetworkCallback networkCallback;
    private android.net.Network underlying;
    private final Runnable recovery = this::recover;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (sessionStore == null) sessionStore = new dev.amirzr.flutter_v2ray_client.v2ray.utils.TunnelSessionStore(this);
        AppConfigs.V2RAY_SERVICE_COMMANDS command = intent == null ? null :
                (AppConfigs.V2RAY_SERVICE_COMMANDS) intent.getSerializableExtra("COMMAND");
        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            desired = false;
            acknowledgeStop = true;
            handler.removeCallbacksAndMessages(null);
            try { sessionStore.markStopped(); } catch (Exception error) { sessionStore.clear(); }
            V2rayCoreManager.getInstance().stopForRestart();
            stopAllProcess();
            return START_NOT_STICKY;
        }
        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY) {
            new Thread(() -> {
                Intent result = new Intent(getPackageName() + ".CONNECTED_V2RAY_SERVER_DELAY").setPackage(getPackageName());
                result.putExtra("DELAY", String.valueOf(V2rayCoreManager.getInstance().getConnectedV2rayServerDelay()));
                sendBroadcast(result);
            }, "VIORA_DELAY").start();
            return desired ? START_STICKY : START_NOT_STICKY;
        }
        try {
            if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
                v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            } else {
                // Android always-on starts without our app command; sticky restarts
                // restore only a session which was not explicitly disconnected.
                // The BIND_VPN_SERVICE-protected component receives this action
                // from Android. isAlwaysOn() may be false before an interface
                // exists, because the platform checks active VPN ownership.
                v2rayConfig = sessionStore.load(intent != null && SERVICE_INTERFACE.equals(intent.getAction()));
            }
            if (v2rayConfig == null) { stopAllProcess(); return START_NOT_STICKY; }
            V2rayCoreManager.getInstance().showStartingNotification(v2rayConfig);
            if (v2rayConfig.REQUIRE_LOCKDOWN && Build.VERSION.SDK_INT < 29) {
                fail("lockdown_required");
                return START_NOT_STICKY;
            }
            desired = true;
            failures = 0;
            sessionStore.save(v2rayConfig);
            watchNetworks();
            if (!startTunnel()) scheduleRecovery();
            handler.removeCallbacks(healthCheck);
            if (desired) handler.postDelayed(healthCheck, 5000);
            return desired ? START_STICKY : START_NOT_STICKY;
        } catch (Exception error) {
            fail("restart_state_failed");
            return START_NOT_STICKY;
        }
    }

    private boolean startTunnel() {
        recovering = true;
        try {
            V2rayCoreManager manager = V2rayCoreManager.getInstance();
            manager.stopForRestart();
            if (manager.isV2rayCoreRunning()) return false;
            if (!establishVpnInterface()) return false;
            // Query after establish: Android's public lockdown API requires
            // active VPN ownership. The TUN captures packets but no core is
            // started until the strict requirement is confirmed. On refusal,
            // close the interface and report failure without downgrading.
            if (v2rayConfig.REQUIRE_LOCKDOWN && !isLockdownEnabled()) {
                fail("lockdown_required");
                return false;
            }
            if (underlying != null) setUnderlyingNetworks(new android.net.Network[]{underlying});
            v2rayConfig.V2RAY_FULL_JSON_CONFIG = Utilities.ensureTunInbound(v2rayConfig.V2RAY_FULL_JSON_CONFIG, v2rayConfig.MTU);
            boolean success = manager.startCore(v2rayConfig, mInterface.getFd());
            if (success) { failures = 0; broadcast(AppConfigs.V2RAY_STATES.V2RAY_CONNECTED, null); }
            return success;
        } catch (Exception error) {
            return false;
        } finally { recovering = false; }
    }

    private void scheduleRecovery() {
        if (!desired || destroyed || recoveryScheduled) return;
        if (!v2rayConfig.RECONNECT || ++failures > v2rayConfig.RETRIES) { fail("reconnect_exhausted"); return; }
        broadcast(AppConfigs.V2RAY_STATES.V2RAY_CONNECTING, null);
        V2rayCoreManager.getInstance().showStartingNotification(v2rayConfig);
        handler.removeCallbacks(recovery);
        recoveryScheduled = true;
        handler.postDelayed(recovery, Math.min(30000, 1000L << failures));
    }

    private void recover() {
        recoveryScheduled = false;
        if (!desired || destroyed || recovering) return;
        if (prepare(this) != null) { fail("permission_denied"); return; }
        if (!startTunnel()) scheduleRecovery();
    }

    private void broadcast(AppConfigs.V2RAY_STATES state, String error) {
        V2rayCoreManager.getInstance().V2RAY_STATE = state;
        Intent status = new Intent(getPackageName() + ".V2RAY_CONNECTION_INFO").setPackage(getPackageName());
        status.putExtra("STATE", state).putExtra("ERROR_CODE", error).putExtra("DURATION", "00:00:00");
        if (Build.VERSION.SDK_INT >= 29) status.putExtra("ALWAYS_ON", isAlwaysOn()).putExtra("LOCKDOWN", isLockdownEnabled());
        sendBroadcast(status);
    }

    private void fail(String code) {
        desired = false;
        handler.removeCallbacks(recovery);
        try { if (sessionStore != null) sessionStore.markStopped(); }
        catch (Exception error) { sessionStore.clear(); }
        V2rayCoreManager.getInstance().stopForRestart();
        broadcast(AppConfigs.V2RAY_STATES.V2RAY_FAILED, code);
        stopAllProcess();
    }

    private android.net.Network findNetwork() {
        android.net.Network best = null;
        for (android.net.Network network : connectivity.getAllNetworks()) {
            android.net.NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps == null || !caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                    !caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
            if (best == null || caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) best = network;
        }
        return best;
    }

    private void networkChanged() {
        if (!desired || destroyed) return;
        android.net.Network next = findNetwork();
        if (java.util.Objects.equals(next, underlying)) return;
        underlying = next;
        setUnderlyingNetworks(next == null ? null : new android.net.Network[]{next});
        if (next == null) return;
        if (v2rayConfig.RECONNECT && !recovering) {
            handler.removeCallbacks(recovery);
            recoveryScheduled = true;
            handler.postDelayed(recovery, 1000);
        }
    }

    private void watchNetworks() {
        if (networkCallback != null) return;
        connectivity = (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        underlying = findNetwork();
        networkCallback = new android.net.ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(android.net.Network network) { networkChanged(); }
            @Override public void onLost(android.net.Network network) { networkChanged(); }
        };
        connectivity.registerNetworkCallback(new android.net.NetworkRequest.Builder()
                .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), networkCallback, handler);
    }

    private boolean establishVpnInterface() {
        Intent prepareIntent = prepare(this);
        if (prepareIntent != null) {
            Log.e("V2rayVPNService", "VPN permission not granted");
            return false;
        }

        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK != null ? v2rayConfig.REMARK : "V2ray");
        builder.setMtu(v2rayConfig.MTU);
        builder.addAddress("26.26.26.1", 30);

        // This release supports IPv4 only. Without an IPv6 address, route or DNS,
        // Android blocks that family by default (VpnService.Builder.allowFamily).
        // Advertising a dummy IPv6 interface would instead make applications
        // attempt IPv6 connections that the core can only discard.
        // Never call allowFamily(AF_INET6) or allowBypass here.

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                String[] parts = subnet.split("/");
                if (parts.length == 2 && !parts[0].contains(":")) {
                    try {
                        builder.addRoute(parts[0], Integer.parseInt(parts[1]));
                    } catch (Exception ignored) {
                    }
                }
            }
        }

        if (v2rayConfig.ALLOWED_APPS != null) {
            int accepted = 0;
            for (String app : v2rayConfig.ALLOWED_APPS) {
                if (getPackageName().equals(app)) continue;
                try {
                    builder.addAllowedApplication(app);
                    accepted++;
                } catch (android.content.pm.PackageManager.NameNotFoundException ignored) {
                }
            }
            // Never widen an empty/removed allow-list to all applications.
            if (accepted == 0) return false;
        } else {
            try {
                builder.addDisallowedApplication(getPackageName());
                if (v2rayConfig.BLOCKED_APPS != null) {
                    for (String app : v2rayConfig.BLOCKED_APPS) {
                        try { builder.addDisallowedApplication(app); }
                        catch (android.content.pm.PackageManager.NameNotFoundException ignored) { }
                    }
                }
            } catch (android.content.pm.PackageManager.NameNotFoundException e) {
                return false;
            }
        }

        // The virtual resolver is handled by Xray's DNS outbound. Retain the
        // previous DNS address for encrypted restart states written by older
        // APKs, until the app supplies the new configuration on reconnect.
        boolean addedDns = false;
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            JSONArray outbounds = json.optJSONArray("outbounds");
            if (outbounds != null) {
                for (int i = 0; i < outbounds.length(); i++) {
                    JSONObject outbound = outbounds.optJSONObject(i);
                    if (outbound != null && "dns-out".equals(outbound.optString("tag")) &&
                            "dns".equals(outbound.optString("protocol"))) {
                        builder.addDnsServer("26.26.26.2");
                        addedDns = true;
                        break;
                    }
                }
            }
            JSONObject dns = json.optJSONObject("dns");
            JSONArray servers = dns == null ? null : dns.optJSONArray("servers");
            if (!addedDns && servers != null) {
                for (int i = 0; i < servers.length(); i++) {
                    Object server = servers.get(i);
                    String address = server instanceof String ? (String) server :
                            server instanceof JSONObject ? ((JSONObject) server).optString("address") : null;
                    if (isPlainIpv4Address(address)) { builder.addDnsServer(address); addedDns = true; }
                }
            }
        } catch (Exception ignored) { }
        if (!addedDns) builder.addDnsServer("1.1.1.1");

        try {
            if (mInterface != null) {
                mInterface.close();
            }
        } catch (Exception ignored) {
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }

        try {
            mInterface = builder.establish();
            if (mInterface == null) {
                return false;
            }
            isRunning = true;
            vpnInterfaceReady = true;
            return true;
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Failed to establish VPN interface", e);
            return false;
        }
    }

    private static boolean isPlainIpv4Address(String value) {
        if (value == null) {
            return false;
        }
        String host = value.trim();
        if (host.isEmpty() || host.contains("/") || host.contains("://")) {
            return false;
        }
        if (host.contains(":")) return false;
        String[] parts = host.split("\\.");
        if (parts.length != 4) {
            return false;
        }
        try {
            for (String part : parts) {
                int n = Integer.parseInt(part);
                if (n < 0 || n > 255) {
                    return false;
                }
            }
            return true;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    private void stopAllProcess() {
        stopForeground(true);
        isRunning = false;
        vpnInterfaceReady = false;
        try {
            stopSelf();
        } catch (Exception e) {
            Log.e("V2rayVPNService", "stopSelf failed", e);
        }
        try {
            if (mInterface != null) {
                mInterface.close();
                mInterface = null;
            }
        } catch (Exception ignored) {
        }
    }

    @Override
    public void onDestroy() {
        Log.i("V2rayVPNService", "onDestroy called - cleaning up resources");
        destroyed = true;
        desired = false;
        handler.removeCallbacksAndMessages(null);
        if (networkCallback != null) {
            try { connectivity.unregisterNetworkCallback(networkCallback); } catch (Exception ignored) { }
            networkCallback = null;
        }
        isRunning = false;
        vpnInterfaceReady = false;

        try {
            if (V2rayCoreManager.getInstance().isV2rayCoreRunning()) {
                V2rayCoreManager.getInstance().stopForRestart();
            }
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error stopping V2ray core in onDestroy", e);
        }

        try {
            stopForeground(true);
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error stopping foreground in onDestroy", e);
        }

        try {
            if (mInterface != null) {
                mInterface.close();
                mInterface = null;
            }
        } catch (Exception e) {
            Log.e("V2rayVPNService", "Error closing VPN interface in onDestroy", e);
        }

        // Acknowledge only once the old core and TUN have been released.
        if (acknowledgeStop) broadcast(AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED, null);
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        acknowledgeStop = true;
        desired = false;
        if (sessionStore != null) sessionStore.clear();
        handler.removeCallbacks(recovery);
        V2rayCoreManager.getInstance().stopForRestart();
        stopAllProcess();
    }

    @Override
    public boolean onProtect(int socket) {
        return protect(socket);
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        // Core Startup callback: VPN interface is already established before startLoop.
        if (vpnInterfaceReady) {
            Log.i("V2rayVPNService", "startService callback ignored (native TUN already ready)");
            return;
        }
        Log.w("V2rayVPNService", "startService callback with VPN not ready");
    }

    @Override
    public void stopService() {
        if (recovering || destroyed) return;
        handler.post(() -> {
            if (desired && v2rayConfig != null && v2rayConfig.RECONNECT) scheduleRecovery();
            else stopAllProcess();
        });
    }
}
