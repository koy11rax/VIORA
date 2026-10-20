#include "platform_bridge.h"
#include "secure_vault.h"
#include "desktop_tunnel.h"
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <regex>
#include <tlhelp32.h>
#include <map>
#include <algorithm>
#include <cwctype>

namespace {
std::string Utf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}
flutter::EncodableList DesktopApplications() {
  std::map<std::wstring, std::wstring> paths;
  const auto add = [&](std::wstring path) {
    if (path.size() < 7 || path.size() > 4096) return;
    if (path.front() == L'"' && path.back() == L'"') path = path.substr(1, path.size()-2);
    if (path.size() < 3 || path[1] != L':') return;
    auto lower = path; std::transform(lower.begin(), lower.end(), lower.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    if (lower.substr(lower.size()-4) != L".exe" || GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    const auto name = lower.substr(lower.find_last_of(L"\\/") + 1);
    if (name == L"viora.exe" || name == L"viora_client.exe" || name == L"viora_tunnel.exe" || name == L"xray.exe") return;
    paths.emplace(lower, path);
  };
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W item{}; item.dwSize = sizeof(item);
    if (Process32FirstW(snapshot, &item)) do {
      HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, item.th32ProcessID);
      if (process) { wchar_t path[4096]; DWORD size = 4096; if (QueryFullProcessImageNameW(process, 0, path, &size)) add(std::wstring(path, size)); CloseHandle(process); }
    } while (Process32NextW(snapshot, &item));
    CloseHandle(snapshot);
  }
  for (const auto hive : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
    HKEY root = nullptr;
    if (RegOpenKeyExW(hive, L"Software\\Microsoft\\Windows\\CurrentVersion\\App Paths", 0, KEY_READ, &root) != ERROR_SUCCESS) continue;
    for (DWORD index = 0;; ++index) {
      wchar_t child[512]; DWORD size = 512;
      const auto error = RegEnumKeyExW(root, index, child, &size, nullptr, nullptr, nullptr, nullptr);
      if (error == ERROR_NO_MORE_ITEMS) break;
      if (error != ERROR_SUCCESS) continue;
      wchar_t path[4096]; DWORD bytes = sizeof(path);
      if (RegGetValueW(root, child, nullptr, RRF_RT_REG_SZ, nullptr, path, &bytes) == ERROR_SUCCESS) add(path);
    }
    RegCloseKey(root);
  }
  flutter::EncodableList result;
  for (const auto& entry : paths) {
    auto path = entry.second; std::replace(path.begin(), path.end(), L'\\', L'/');
    const auto name = path.substr(path.find_last_of(L'/') + 1);
    result.emplace_back(flutter::EncodableMap{{flutter::EncodableValue("id"), flutter::EncodableValue("windows:" + Utf8(path))}, {flutter::EncodableValue("name"), flutter::EncodableValue(Utf8(name))}});
  }
  return result;
}
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> RegisterVioraPlatform(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "dev.viora/platform", &flutter::StandardMethodCodec::GetInstance());
  auto vault = std::make_shared<SecureVault>();
  auto tunnel = std::make_shared<DesktopTunnel>();
  channel->SetMethodCallHandler([vault, tunnel](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "applications") { result->Success(flutter::EncodableValue(DesktopApplications())); return; }
    std::string value;
    const auto* arguments = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto argument = [&](const char* key) -> const std::string* {
      if (!arguments) return nullptr;
      const auto found = arguments->find(flutter::EncodableValue(key));
      return found == arguments->end() ? nullptr : std::get_if<std::string>(&found->second);
    };
    if (method == "desktopProtection") {
      const auto* action=argument("action");
      result->Success(flutter::EncodableValue(action?DesktopTunnel::Protection(*action):"ERROR"));return;
    }
    if (method == "desktopTunnelStart") {
      const auto* config = argument("config");
      if (!config || !tunnel->Start(*config)) { result->Error("tunnel_busy", "Cannot start desktop tunnel"); return; }
      result->Success(); return;
    }
    if (method == "desktopTunnelStop") { tunnel->Stop(); result->Success(); return; }
    if (method == "desktopTunnelPoll") { result->Success(flutter::EncodableValue(tunnel->Poll())); return; }
    if (method == "openTelegram") {
      const auto* url = argument("url");
      static const std::regex allowed("^https://t\\.me/[A-Za-z][A-Za-z0-9_]{4,31}(\\?start=[A-Za-z0-9_-]{1,80})?$");
      if (!url || !std::regex_match(*url, allowed)) { result->Error("invalid_url", "Invalid Telegram URL"); return; }
      // Validation limits this URL to ASCII, so no locale conversion is needed.
      const std::wstring wide(url->begin(), url->end());
      if (reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <= 32) {
        result->Error("open_failed", "Cannot open Telegram"); return;
      }
      result->Success(); return;
    }
    bool ok = false;
    std::optional<std::string> saved;
    if (method == "installationId") {
      ok = vault->InstallationId(&value);
      if (ok) saved = value;
    } else if (method == "readSession" || method == "readProfiles") {
      ok = vault->Read(method == "readSession" ? "session" : "profiles", &saved);
    } else if (method == "saveSession" || method == "saveProfiles") {
      const auto* input = argument("value");
      if (!input || (method == "saveSession" && !std::regex_match(*input, std::regex("^[A-Za-z0-9_-]{43}$")))) {
        result->Error("invalid_value", "Invalid protected value"); return;
      }
      ok = vault->Write(method == "saveSession" ? "session" : "profiles", *input);
    } else if (method == "clearSession") {
      ok = vault->Remove("session");
    } else { result->NotImplemented(); return; }
    if (!ok) { result->Error("vault_unavailable", "Cannot access Windows protected storage"); return; }
    if (saved) result->Success(flutter::EncodableValue(*saved)); else result->Success();
  });
  return channel;
}
