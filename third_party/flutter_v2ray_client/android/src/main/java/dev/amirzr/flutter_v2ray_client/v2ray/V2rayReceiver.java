package dev.amirzr.flutter_v2ray_client.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.util.ArrayList;

import io.flutter.plugin.common.EventChannel;

public class V2rayReceiver extends BroadcastReceiver {
    public static EventChannel.EventSink vpnStatusSink;

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            // Validate inputs
            if (intent == null) {
                Log.w("V2rayReceiver", "Received null intent");
                return;
            }

            if (intent.getExtras() == null) {
                Log.w("V2rayReceiver", "Intent has no extras");
                return;
            }

            if (vpnStatusSink == null) {
                Log.w("V2rayReceiver", "vpnStatusSink is null, cannot send status");
                return;
            }

            ArrayList<String> list = new ArrayList<>();
            String duration = intent.getExtras().getString("DURATION");
            list.add(duration != null ? duration : "00:00:00");
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_TRAFFIC", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)));

            Object state = intent.getExtras().getSerializable("STATE");
            if (state != null) {
                String stateStr = state.toString();
                list.add(stateStr.length() > 6 ? stateStr.substring(6) : stateStr);
            } else {
                list.add("DISCONNECTED");
            }

            list.add(intent.getStringExtra("ERROR_CODE") == null ? "" : intent.getStringExtra("ERROR_CODE"));
            list.add(Boolean.toString(intent.getBooleanExtra("ALWAYS_ON", false)));
            list.add(Boolean.toString(intent.getBooleanExtra("LOCKDOWN", false)));
            list.add(Boolean.toString(intent.getBooleanExtra("EXTERNAL_START", false)));
            vpnStatusSink.success(list);
        } catch (Exception e) {
            Log.e("V2rayReceiver", "onReceive failed", e);
        }
    }

}
