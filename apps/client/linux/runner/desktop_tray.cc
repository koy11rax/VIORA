#include "desktop_tray.h"
#include <libayatana-appindicator/app-indicator.h>
#include <string>

namespace {
struct Tray;
struct Action { Tray* owner; std::string command; int64_t id; };
struct Tray {
  GtkWindow* window;
  FlMethodChannel* channel;
  AppIndicator* indicator;
  GtkWidget* menu;
  FlValue* state = nullptr;
  bool connected = false;
  bool pending = false;
  guint idle_source = 0;
  std::string signature;
  GtkWidget* status_item = nullptr;
  GtkWidget* details_item = nullptr;
  GtkWidget* speed_item = nullptr;
};
FlValue* field(Tray* tray, const char* key) {
  return tray->state ? fl_value_lookup_string(tray->state, key) : nullptr;
}
bool flag(Tray* tray, const char* key) {
  auto* value = field(tray, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
}
const char* text(Tray* tray, const char* key) {
  auto* value = field(tray, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
void restore(Tray* tray) { gtk_widget_show(GTK_WIDGET(tray->window)); gtk_window_present(tray->window); }
void action_cb(GtkMenuItem*, gpointer data) {
  auto* action = static_cast<Action*>(data);
  if (action->command == "open") { restore(action->owner); return; }
  if (action->command == "exit") { g_application_quit(g_application_get_default()); return; }
  if (action->command == "settings" || action->command == "ping" || action->command == "refresh") restore(action->owner);
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "command", fl_value_new_string(action->command.c_str()));
  if (action->command == "server") fl_value_set_string_take(args, "id", fl_value_new_int(action->id));
  fl_method_channel_invoke_method(action->owner->channel, "action", args, nullptr, nullptr, nullptr);
}
GtkWidget* item(Tray* tray, GtkWidget* menu, const char* label, const char* command = nullptr, bool enabled = true, int64_t id = 0) {
  GtkWidget* row = gtk_menu_item_new_with_label(label);
  gtk_widget_set_sensitive(row, enabled);
  if (command) {
    auto* action = new Action{tray, command, id};
    g_object_set_data_full(G_OBJECT(row), "viora-action", action, [](gpointer data) { delete static_cast<Action*>(data); });
    g_signal_connect(row, "activate", G_CALLBACK(action_cb), action);
  }
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), row);
  return row;
}
void rebuild(Tray* tray) {
  auto* server_list = field(tray, "servers");
  g_autofree char* server_text = server_list ? fl_value_to_string(server_list) : g_strdup("");
  const std::string signature = std::string(server_text) + (flag(tray, "busy") ? "1" : "0") + (flag(tray, "running") ? "1" : "0") + (flag(tray, "canConnect") ? "1" : "0") + (flag(tray, "subscriptions") ? "1" : "0");
  if (tray->status_item && tray->signature == signature) {
    // Do not recreate a D-Bus menu every second while its remote popup is open.
    // Updating the existing labels preserves the menu and keyboard selection.
    gtk_menu_item_set_label(GTK_MENU_ITEM(tray->status_item), text(tray, "status"));
    gtk_menu_item_set_label(GTK_MENU_ITEM(tray->details_item), text(tray, "details"));
    gtk_menu_item_set_label(GTK_MENU_ITEM(tray->speed_item), text(tray, "speed"));
    gtk_widget_set_visible(tray->details_item, *text(tray, "details"));
    gtk_widget_set_visible(tray->speed_item, *text(tray, "speed"));
    app_indicator_set_title(tray->indicator, text(tray, "status"));
    return;
  }
  if (gtk_widget_get_mapped(tray->menu)) { tray->pending = true; return; }
  tray->pending = false;
  tray->signature = signature;
  GList* children = gtk_container_get_children(GTK_CONTAINER(tray->menu));
  for (GList* child = children; child; child = child->next) gtk_widget_destroy(GTK_WIDGET(child->data));
  g_list_free(children);
  const char* status = text(tray, "status");
  tray->status_item = item(tray, tray->menu, *status ? status : "VIORA запускается…", nullptr, false);
  tray->details_item = item(tray, tray->menu, text(tray, "details"), nullptr, false);
  tray->speed_item = item(tray, tray->menu, text(tray, "speed"), nullptr, false);
  gtk_menu_shell_append(GTK_MENU_SHELL(tray->menu), gtk_separator_menu_item_new());
  item(tray, tray->menu, "Открыть VIORA", "open");
  const bool busy = flag(tray, "busy"), running = flag(tray, "running");
  item(tray, tray->menu, running ? "Отключиться" : "Подключиться", "toggle", !busy && (running || flag(tray, "canConnect")));
  GtkWidget* servers = gtk_menu_new();
  GtkWidget* parent = item(tray, tray->menu, "Выбрать сервер");
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(parent), servers);
  auto* list = field(tray, "servers");
  size_t count = list && fl_value_get_type(list) == FL_VALUE_TYPE_LIST ? fl_value_get_length(list) : 0;
  for (size_t i = 0; i < count && i < 1000; ++i) {
    auto* server = fl_value_get_list_value(list, i);
    if (fl_value_get_type(server) != FL_VALUE_TYPE_MAP) continue;
    auto* id = fl_value_lookup_string(server, "id"); auto* name = fl_value_lookup_string(server, "name"); auto* selected = fl_value_lookup_string(server, "selected");
    if (!id || fl_value_get_type(id) != FL_VALUE_TYPE_INT || !name || fl_value_get_type(name) != FL_VALUE_TYPE_STRING) continue;
    const bool checked = selected && fl_value_get_type(selected) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(selected);
    std::string label = (checked ? "✓ " : "") + std::string(fl_value_get_string(name));
    item(tray, servers, label.c_str(), "server", !busy, fl_value_get_int(id));
  }
  if (count == 0) item(tray, servers, "Нет серверов", nullptr, false);
  item(tray, tray->menu, "Обновить подписки", "refresh", flag(tray, "subscriptions") && !busy);
  item(tray, tray->menu, "Проверить пинг", "ping", flag(tray, "canConnect") && !busy);
  item(tray, tray->menu, "Настройки", "settings");
  gtk_menu_shell_append(GTK_MENU_SHELL(tray->menu), gtk_separator_menu_item_new());
  item(tray, tray->menu, "Выйти из VIORA", "exit");
  gtk_widget_show_all(tray->menu);
  gtk_widget_set_visible(tray->details_item, *text(tray, "details"));
  gtk_widget_set_visible(tray->speed_item, *text(tray, "speed"));
  app_indicator_set_title(tray->indicator, *status ? status : "VIORA");
}
void method_cb(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* tray = static_cast<Tray*>(data);
  const char* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "update") == 0) {
    auto* args = fl_method_call_get_args(call);
    if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) { fl_method_call_respond_error(call, "invalid_state", "Expected tray state", nullptr, nullptr); return; }
    if (tray->state) fl_value_unref(tray->state);
    tray->state = fl_value_ref(args);
    rebuild(tray);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "showMenu") == 0) {
    rebuild(tray); gtk_menu_popup_at_pointer(GTK_MENU(tray->menu), nullptr);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
}

FlMethodChannel* register_viora_tray(FlView* view, GtkWindow* window) {
  auto* tray = new Tray{};
  tray->window = GTK_WINDOW(g_object_ref(window));
  tray->indicator = app_indicator_new("viora", "viora", APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  tray->menu = gtk_menu_new(); g_object_ref_sink(tray->menu);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  tray->channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "dev.viora/tray", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(tray->channel, method_cb, tray, [](gpointer data) {
    auto* value = static_cast<Tray*>(data);
    if (value->idle_source) g_source_remove(value->idle_source);
    g_signal_handlers_disconnect_by_data(value->window, value);
    app_indicator_set_status(value->indicator, APP_INDICATOR_STATUS_PASSIVE);
    g_object_unref(value->indicator); gtk_widget_destroy(value->menu); g_object_unref(value->menu);
    if (value->state) fl_value_unref(value->state);
    g_object_unref(value->window); delete value;
  });
  g_signal_connect(window, "delete-event", G_CALLBACK(+[](GtkWidget* widget, GdkEvent*, gpointer data) -> gboolean {
    auto* value = static_cast<Tray*>(data);
    if (value->connected) gtk_widget_hide(widget); else gtk_window_iconify(GTK_WINDOW(widget));
    return TRUE;
  }), tray);
  g_signal_connect(tray->indicator, "connection-changed", G_CALLBACK(+[](AppIndicator*, gboolean connected, gpointer data) {
    auto* value = static_cast<Tray*>(data); value->connected = connected;
    if (!connected && !gtk_widget_get_visible(GTK_WIDGET(value->window))) restore(value);
  }), tray);
  g_signal_connect(tray->menu, "deactivate", G_CALLBACK(+[](GtkWidget*, gpointer data) {
    auto* value = static_cast<Tray*>(data);
    // Rebuild only after the menu has fully unmapped, never during tracking.
    if (value->pending && !value->idle_source) value->idle_source = g_idle_add(+[](gpointer data) -> gboolean { auto* value = static_cast<Tray*>(data); value->idle_source = 0; rebuild(value); return G_SOURCE_REMOVE; }, value);
  }), tray);
  rebuild(tray); app_indicator_set_menu(tray->indicator, GTK_MENU(tray->menu));
  app_indicator_set_status(tray->indicator, APP_INDICATOR_STATUS_ACTIVE);
  return tray->channel;
}
