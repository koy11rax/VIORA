package dev.amirzr.flutter_v2ray_client.v2ray.utils;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Service-process-owned, atomic encrypted restart state; never Java deserialization. */
public final class TunnelSessionStore {
    private static final String ALIAS = "viora.tunnel.restart.v1";
    private final AtomicFile file;
    public TunnelSessionStore(Context context) {
        file = new AtomicFile(new File(context.getNoBackupFilesDir(), "tunnel-session.enc"));
    }
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(ALIAS)) return (SecretKey) store.getKey(ALIAS, null);
        if (file.getBaseFile().exists()) throw new IllegalStateException("Missing restart key");
        KeyGenerator generator = KeyGenerator.getInstance("AES", "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    private JSONObject read() throws Exception {
        if (!file.getBaseFile().exists()) return null;
        if (file.getBaseFile().length() > 524288) throw new IllegalStateException("Oversized restart state");
        JSONObject envelope = new JSONObject(new String(file.readFully(), StandardCharsets.UTF_8));
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128,
                Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)));
        cipher.updateAAD(ALIAS.getBytes(StandardCharsets.UTF_8));
        return new JSONObject(new String(cipher.doFinal(Base64.decode(envelope.getString("data"),
                Base64.NO_WRAP)), StandardCharsets.UTF_8));
    }
    private void write(JSONObject value) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        cipher.updateAAD(ALIAS.getBytes(StandardCharsets.UTF_8));
        JSONObject envelope = new JSONObject()
                .put("iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .put("data", Base64.encodeToString(cipher.doFinal(value.toString().getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP));
        byte[] encoded = envelope.toString().getBytes(StandardCharsets.UTF_8);
        if (encoded.length > 524288) throw new IllegalStateException("Oversized restart state");
        FileOutputStream output = file.startWrite();
        try {
            output.write(encoded);
            file.finishWrite(output);
        } catch (Exception failure) {
            file.failWrite(output);
            throw failure;
        }
    }
    public void save(V2rayConfig config) throws Exception {
        JSONObject value = new JSONObject().put("version", 1).put("wanted", true)
                .put("config", config.V2RAY_FULL_JSON_CONFIG).put("name", config.REMARK)
                .put("mtu", config.MTU).put("reconnect", config.RECONNECT)
                .put("retries", config.RETRIES).put("strict", config.REQUIRE_LOCKDOWN);
        if (config.ALLOWED_APPS != null) value.put("allowed", new JSONArray(config.ALLOWED_APPS));
        if (config.BLOCKED_APPS != null) value.put("blocked", new JSONArray(config.BLOCKED_APPS));
        write(value);
    }
    public V2rayConfig load(boolean systemRequested) throws Exception {
        JSONObject value = read();
        if (value == null || (!systemRequested && !value.getBoolean("wanted"))) return null;
        if (value.getInt("version") != 1) throw new IllegalStateException("Invalid restart state");
        AppConfigs.APPLICATION_NAME = "Viora";
        AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = "Отключить";
        V2rayConfig config = Utilities.parseV2rayJsonFile(value.getString("name"),
                value.getString("config"), list(value, "blocked"), null);
        if (config == null) throw new IllegalStateException("Invalid restart config");
        config.ALLOWED_APPS = list(value, "allowed");
        config.MTU = value.getInt("mtu");
        config.RECONNECT = value.getBoolean("reconnect");
        config.RETRIES = value.getInt("retries");
        config.REQUIRE_LOCKDOWN = value.getBoolean("strict");
        if (config.MTU < 1280 || config.MTU > 1500 || config.RETRIES < 1 || config.RETRIES > 5 ||
                (config.ALLOWED_APPS != null && config.ALLOWED_APPS.isEmpty()))
            throw new IllegalStateException("Invalid restart options");
        return config;
    }
    private static ArrayList<String> list(JSONObject value, String key) throws Exception {
        if (!value.has(key)) return null;
        JSONArray array = value.getJSONArray(key);
        if (array.length() > 1000) throw new IllegalStateException("Oversized app list");
        ArrayList<String> list = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) list.add(array.getString(i));
        return list;
    }
    public void markStopped() throws Exception {
        JSONObject value = read();
        if (value != null) { value.put("wanted", false); write(value); }
    }
    public void clear() { file.delete(); }
}
