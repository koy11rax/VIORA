#include "platform_bridge.h"
#include <libsecret/secret.h>
#include <sys/random.h>
#include <cerrno>
#include <cstring>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <set>
#include <cstdlib>

namespace {
FlValue* desktop_applications() {
  FlValue* rows = fl_value_new_list();
  std::set<std::string> known;
  GList* apps = g_app_info_get_all();
  for (GList* item = apps; item; item = item->next) {
    auto* app = G_APP_INFO(item->data);
    if (!g_app_info_should_show(app)) continue;
    const char* executable = g_app_info_get_executable(app);
    if (!executable) continue;
    g_autofree char* found = g_path_is_absolute(executable) ? g_strdup(executable) : g_find_program_in_path(executable);
    if (!found || !g_file_test(found, G_FILE_TEST_IS_EXECUTABLE)) continue;
    char* resolved = realpath(found, nullptr);
    std::string path = resolved ? resolved : found;
    free(resolved);
    if (path == "/usr/lib/viora/viora_client" || !known.insert(path).second) continue;
    FlValue* row = fl_value_new_map();
    fl_value_set_string_take(row, "id", fl_value_new_string(("linux:" + path).c_str()));
    fl_value_set_string_take(row, "name", fl_value_new_string(g_app_info_get_display_name(app)));
    fl_value_append_take(rows, row);
  }
  g_list_free_full(apps, g_object_unref);
  return rows;
}
std::mutex vault_mutex;
void wipe(std::string& value) {
  if (!value.empty()) {
    volatile char* bytes = &value[0];
    for (size_t i = 0; i < value.size(); ++i) bytes[i] = 0;
  }
}
const SecretSchema* schema() {
  static SecretSchema* value = secret_schema_new("dev.viora.Vault", SECRET_SCHEMA_NONE,
    "item", SECRET_SCHEMA_ATTRIBUTE_STRING, nullptr);
  return value;
}
struct Request {
  FlMethodCall* call;
  std::string method, value;
  ~Request() { wipe(value); g_object_unref(call); }
};
struct Result {
  bool ok = false, has_value = false;
  std::string value;
  ~Result() { wipe(value); }
};
bool lookup(const char* item, Result* result) {
  g_autoptr(GError) error = nullptr;
  gchar* value = secret_password_lookup_sync(schema(), nullptr, &error, "item", item, nullptr);
  if (error) { if (value) secret_password_free(value); return false; }
  if (value) {
    result->value = value;
    result->has_value = true;
    secret_password_free(value);
    if (result->value.size() > 1048576) return false;
  }
  return true;
}
bool store(const char* item, const std::string& value) {
  g_autoptr(GError) error = nullptr;
  return secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT,
    "Viora protected data", value.c_str(), nullptr, &error, "item", item, nullptr) && !error;
}
void worker(GTask* task, gpointer, gpointer data, GCancellable*) {
  std::lock_guard<std::mutex> lock(vault_mutex);
  const auto* request = static_cast<Request*>(data);
  auto result = std::make_unique<Result>();
  const auto& method = request->method;
  if (method == "readSession" || method == "readProfiles") {
    result->ok = lookup(method == "readSession" ? "session" : "profiles", result.get());
  } else if (method == "saveSession" || method == "saveProfiles") {
    result->ok = store(method == "saveSession" ? "session" : "profiles", request->value);
  } else if (method == "clearSession") {
    g_autoptr(GError) error = nullptr;
    secret_password_clear_sync(schema(), nullptr, &error, "item", "session", nullptr);
    result->ok = !error; // An already missing item is also cleared.
  } else if (method == "installationId") {
    result->ok = lookup("installation", result.get());
    if (result->ok && !result->has_value) {
      unsigned char bytes[16];
      size_t received = 0;
      while (received < sizeof(bytes)) {
        const auto count = getrandom(bytes + received, sizeof(bytes) - received, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result->ok = false; break; }
        received += static_cast<size_t>(count);
      }
      if (result->ok) {
        constexpr char hex[] = "0123456789abcdef";
        for (auto b : bytes) { result->value += hex[b >> 4]; result->value += hex[b & 15]; }
        result->has_value = true;
        result->ok = store("installation", result->value);
      }
      explicit_bzero(bytes, sizeof(bytes));
    }
    if (result->ok) result->ok = result->value.size() == 32 && result->value.find_first_not_of("0123456789abcdef") == std::string::npos;
  }
  g_task_return_pointer(task, result.release(), [](gpointer p) { delete static_cast<Result*>(p); });
}
void completed(GObject*, GAsyncResult* async_result, gpointer) {
  auto* task = G_TASK(async_result);
  const auto* request = static_cast<Request*>(g_task_get_task_data(task));
  std::unique_ptr<Result> result(static_cast<Result*>(g_task_propagate_pointer(task, nullptr)));
  g_autoptr(FlMethodResponse) response = nullptr;
  if (!result || !result->ok) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new("vault_unavailable", "Unlock your system keyring to access Viora protected storage", nullptr));
  } else {
    g_autoptr(FlValue) value = result->has_value ? fl_value_new_string(result->value.c_str()) : fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  }
  fl_method_call_respond(request->call, response, nullptr);
}
void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  const auto argument = [&](const char* key) -> const gchar* {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
    FlValue* item = fl_value_lookup_string(args, key);
    return item && fl_value_get_type(item) == FL_VALUE_TYPE_STRING ? fl_value_get_string(item) : nullptr;
  };
  if (method == "openTelegram") {
    const auto* url = argument("url");
    static const std::regex allowed("^https://t\\.me/[A-Za-z][A-Za-z0-9_]{4,31}(\\?start=[A-Za-z0-9_-]{1,80})?$");
    if (!url || strlen(url) > 256 || !std::regex_match(url, allowed)) {
      fl_method_call_respond_error(call, "invalid_url", "Invalid Telegram URL", nullptr, nullptr); return;
    }
    g_autoptr(GError) error = nullptr;
    if (!g_app_info_launch_default_for_uri(url, nullptr, &error)) {
      fl_method_call_respond_error(call, "open_failed", "Cannot open Telegram", nullptr, nullptr);
    } else fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (method == "applications") {
    g_autoptr(FlValue) rows = desktop_applications();
    fl_method_call_respond_success(call, rows, nullptr); return;
  }
  if (method != "installationId" && method != "readSession" && method != "readProfiles" &&
      method != "saveSession" && method != "saveProfiles" && method != "clearSession") {
    fl_method_call_respond_not_implemented(call, nullptr); return;
  }
  const auto* value = argument("value");
  if ((method == "saveSession" || method == "saveProfiles") &&
      (!value || strlen(value) == 0 || strlen(value) > 1048576 ||
       (method == "saveSession" && !std::regex_match(value, std::regex("^[A-Za-z0-9_-]{43}$"))))) {
    fl_method_call_respond_error(call, "invalid_value", "Invalid protected value", nullptr, nullptr); return;
  }
  auto* request = new Request{FL_METHOD_CALL(g_object_ref(call)), method, value ? value : ""};
  g_autoptr(GTask) task = g_task_new(nullptr, nullptr, completed, nullptr);
  g_task_set_task_data(task, request, [](gpointer p) { delete static_cast<Request*>(p); });
  g_task_run_in_thread(task, worker);
}
}
FlMethodChannel* register_viora_platform(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "dev.viora/platform", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, nullptr, nullptr);
  return channel;
}
