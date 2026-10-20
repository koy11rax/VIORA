#include "flutter_window.h"
#include "platform_bridge.h"
#include "resource.h"

#include <optional>
#include <vector>
#include <algorithm>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kTrayCallback = WM_APP + 42;
constexpr UINT kTrayOpen = 1;
constexpr UINT kTrayExit = 2;
constexpr UINT kTrayToggle = 3;
constexpr UINT kTrayRefresh = 4;
constexpr UINT kTrayPing = 5;
constexpr UINT kTraySettings = 6;
constexpr UINT kTrayServerBase = 100;
constexpr UINT_PTR kTrayTimer = 4342;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
const Value* Field(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : &found->second;
}
bool Flag(const Map& map, const char* name) {
  const auto* value = Field(map, name);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}
std::wstring Wide(const std::string& value) {
  const int count = MultiByteToWideChar(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(count, 0);
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), count);
  return result;
}
std::wstring Text(const Map& map, const char* name) {
  const auto* value = Field(map, name);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? Wide(*text) : L"";
}
// A real top-level window must retain the benign WM_NULL after TrackPopupMenu.
// Do not use STATIC: its control procedure forwards activation to its parent.
LRESULT CALLBACK TrayOwnerProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  return DefWindowProcW(hwnd, msg, wp, lp);
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  platform_channel_ = RegisterVioraPlatform(flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  restore_message_ = RegisterWindowMessageW(L"Viora.RestoreWindow");
  WNDCLASSW owner_class{};
  owner_class.lpfnWndProc = TrayOwnerProc;
  owner_class.hInstance = GetModuleHandleW(nullptr);
  owner_class.lpszClassName = L"VIORA_TRAY_OWNER";
  RegisterClassW(&owner_class);
  tray_owner_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
      owner_class.lpszClassName, L"VIORA tray menu", WS_POPUP,
      0, 0, 1, 1, nullptr, nullptr, owner_class.hInstance, nullptr);
  if (tray_owner_) SetLayeredWindowAttributes(tray_owner_, 0, 0, LWA_ALPHA);
  AddTrayIcon();
  tray_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.viora/tray",
      &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "showMenu") {
      if (!tray_menu_open_ && !tray_menu_pending_) {
        GetCursorPos(&tray_point_);
        tray_menu_pending_ = SetTimer(GetHandle(), kTrayTimer, 100, nullptr) != 0;
      }
      result->Success();
      return;
    }
    const auto* state = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (call.method_name() != "update" || !state) {
      result->NotImplemented();
      return;
    }
    tray_state_ = *state;
    const auto details = Text(tray_state_, "details");
    const auto tip = L"VIORA · " + Text(tray_state_, "status") + (details.empty() ? L"" : L"\n" + details);
    wcsncpy_s(tray_icon_.szTip, tip.c_str(), _TRUNCATE);
    if (tray_added_) Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
    result->Success();
  });
  frame_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.viora/window",
      &flutter::StandardMethodCodec::GetInstance());
  frame_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "setDark") {
      result->NotImplemented();
      return;
    }
    const auto* dark = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
    if (!dark) {
      result->Error("invalid_argument", "Expected a boolean");
      return;
    }
    SetFrameTheme(*dark);
    result->Success();
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  KillTimer(GetHandle(), kTrayTimer);
  if (tray_menu_open_) EndMenu();
  RemoveTrayIcon();
  if (tray_owner_) DestroyWindow(tray_owner_);
  tray_owner_ = nullptr;
  tray_channel_.reset();
  frame_channel_.reset();
  platform_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle closing before plugins: hiding must keep Flutter and its VPN IPC alive.
  if (message == WM_CLOSE && !exiting_) {
    if (tray_added_ || AddTrayIcon()) {
      ShowWindow(hwnd, SW_HIDE);
    } else {
      // A missing shell/tray must never strand an invisible application.
      ShowWindow(hwnd, SW_MINIMIZE);
    }
    return 0;
  }
  if (taskbar_created_ && message == taskbar_created_) {
    tray_added_ = false;
    if (!AddTrayIcon() && !IsWindowVisible(hwnd)) RestoreFromTray();
    return 0;
  }
  if (restore_message_ && message == restore_message_) {
    RestoreFromTray();
    return 0;
  }
  if (message == kTrayCallback) {
    const UINT event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK) {
      RestoreFromTray();
    } else if (event == WM_CONTEXTMENU && !tray_menu_open_ && !tray_menu_pending_) {
      // VERSION_4 sends WM_CONTEXTMENU. Handling WM_RBUTTONUP as well could
      // reenter tracking and dismiss the first menu. Let Explorer finish its
      // own overflow/focus handling before activating our menu owner.
      tray_point_ = {static_cast<short>(LOWORD(wparam)),
                     static_cast<short>(HIWORD(wparam))};
      if (tray_point_.x == -1 && tray_point_.y == -1) GetCursorPos(&tray_point_);
      tray_menu_pending_ = SetTimer(hwnd, kTrayTimer, 100, nullptr) != 0;
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == kTrayTimer) {
    KillTimer(hwnd, kTrayTimer);
    tray_menu_pending_ = false;
    ShowTrayMenu();
    return 0;
  }
  if (message == WM_ENDSESSION && wparam) exiting_ = true;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      // Keep navigation and dialogs usable when the window is resized.
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      info->ptMinTrackSize.x = MulDiv(480, dpi, 96);
      info->ptMinTrackSize.y = MulDiv(600, dpi, 96);
      MONITORINFO monitor = {};
      monitor.cbSize = sizeof(monitor);
      if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
        info->ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
        info->ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
        info->ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
        info->ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::AddTrayIcon() {
  if (tray_added_) return true;
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayCallback;
  tray_icon_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"VIORA");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
  if (tray_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
  return tray_added_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_added_ = false;
}

void FlutterWindow::RestoreFromTray() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  if (tray_menu_open_ || !tray_owner_ || exiting_) return;
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  tray_menu_open_ = true;
  const bool busy = Flag(tray_state_, "busy");
  const bool running = Flag(tray_state_, "running");
  auto status = Text(tray_state_, "status");
  if (status.empty()) status = L"VIORA запускается…";
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status.c_str());
  const auto details = Text(tray_state_, "details");
  const auto speed = Text(tray_state_, "speed");
  if (!details.empty()) AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, details.c_str());
  if (!speed.empty()) AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, speed.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayOpen, L"Открыть VIORA");
  AppendMenuW(menu, MF_STRING | ((busy || (!running && !Flag(tray_state_, "canConnect")))
      ? MF_GRAYED : 0), kTrayToggle, running ? L"Отключить VPN" : L"Подключиться");
  std::vector<Value> server_ids;
  HMENU servers = CreatePopupMenu();
  const auto* list_value = Field(tray_state_, "servers");
  const auto* list = list_value ? std::get_if<flutter::EncodableList>(list_value) : nullptr;
  if (servers && list) {
    for (const auto& item : *list) {
      const auto* server = std::get_if<Map>(&item);
      if (!server || server_ids.size() >= 200) continue;
      const auto* id = Field(*server, "id");
      if (!id) continue;
      auto name = Text(*server, "name");
      // Display imported ampersands literally rather than as menu accelerators.
      for (size_t i = 0; (i = name.find(L'&', i)) != std::wstring::npos; i += 2)
        name.insert(i, 1, L'&');
      const UINT command = kTrayServerBase + static_cast<UINT>(server_ids.size());
      server_ids.push_back(*id);
      AppendMenuW(servers, MF_STRING | (busy ? MF_GRAYED : 0) |
          (Flag(*server, "selected") ? MF_CHECKED : 0), command, name.c_str());
    }
  }
  if (servers) {
    if (server_ids.empty()) AppendMenuW(servers, MF_STRING | MF_GRAYED, 0, L"Нет серверов");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(servers), L"Выбрать сервер");
  }
  AppendMenuW(menu, MF_STRING | (!Flag(tray_state_, "subscriptions") ? MF_GRAYED : 0),
      kTrayRefresh, L"Обновить подписки");
  AppendMenuW(menu, MF_STRING | (!Flag(tray_state_, "canConnect") ? MF_GRAYED : 0),
      kTrayPing, L"Проверить пинг");
  AppendMenuW(menu, MF_STRING, kTraySettings, L"Настройки");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExit, L"Выйти из VIORA");
  SetMenuDefaultItem(menu, kTrayOpen, FALSE);
  SetWindowPos(tray_owner_, HWND_TOPMOST, tray_point_.x, tray_point_.y, 1, 1,
      SWP_SHOWWINDOW);
  SetForegroundWindow(tray_owner_);
  const UINT selected = TrackPopupMenu(menu,
      TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_NOANIMATION,
      tray_point_.x, tray_point_.y, 0, tray_owner_, nullptr);
  PostMessageW(tray_owner_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  ShowWindow(tray_owner_, SW_HIDE);
  tray_menu_open_ = false;
  Map action;
  if (selected == kTrayOpen) RestoreFromTray();
  else if (selected == kTrayExit) {
    exiting_ = true;
    PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
  } else if (selected >= kTrayServerBase && selected - kTrayServerBase < server_ids.size()) {
    action[Value("command")] = Value("server");
    action[Value("id")] = server_ids[selected - kTrayServerBase];
  } else {
    const char* command = selected == kTrayToggle ? "toggle" :
        selected == kTrayRefresh ? "refresh" : selected == kTrayPing ? "ping" :
        selected == kTraySettings ? "settings" : nullptr;
    if (command) action[Value("command")] = Value(command);
    if (selected == kTraySettings || selected == kTrayPing || selected == kTrayRefresh)
      RestoreFromTray();
  }
  if (!action.empty() && tray_channel_)
    tray_channel_->InvokeMethod("action", std::make_unique<Value>(action));
  if (!selected) Shell_NotifyIconW(NIM_SETFOCUS, &tray_icon_);
}
