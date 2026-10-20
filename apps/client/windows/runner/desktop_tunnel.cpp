#include "desktop_tunnel.h"
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <sddl.h>
#include <bcrypt.h>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <thread>
#include <vector>

struct DesktopTunnel::Session {
  std::atomic<bool> running{true}, stop{false};
  std::mutex mutex;
  std::string pending;
  void Emit(const std::string& value) {
    std::lock_guard<std::mutex> lock(mutex);
    if (pending.size() > 32768) pending.clear();
    pending += value + "\n";
  }
  void Fail(const char* code) { Emit(std::string("{\"state\":\"FAILED\",\"code\":\"") + code + "\"}"); }
};

namespace {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
bool PipeSecurity(PSECURITY_DESCRIPTOR* descriptor) {
  Handle token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value)) return false;
  DWORD size = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size)) return false;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &sid)) return false;
  std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;" + std::wstring(sid) + L")";
  LocalFree(sid);
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, descriptor, nullptr) != FALSE;
}
DWORD ServiceSession(const std::wstring& pipe_name, std::string* reply_out=nullptr) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return 0;
  SC_HANDLE service = OpenServiceW(manager, L"VioraTunnel", SERVICE_QUERY_STATUS);
  CloseServiceHandle(manager);
  if (!service) return 0;
  SERVICE_STATUS_PROCESS status{}; DWORD needed = 0;
  const bool running = QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<BYTE*>(&status), sizeof(status), &needed) &&
      status.dwCurrentState == SERVICE_RUNNING && status.dwProcessId != 0;
  CloseServiceHandle(service);
  if (!running) return 0;
  Handle broker;
  broker.value = CreateFileW(L"\\\\.\\pipe\\Viora.Control.v1", GENERIC_READ | GENERIC_WRITE,
      0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
  if (broker.value == INVALID_HANDLE_VALUE) return 0;
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(broker.value, &server) || server != status.dwProcessId) return 0;
  const auto transfer = [&](bool reading, void* bytes, DWORD size, DWORD* count) {
    Handle event; event.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    OVERLAPPED operation{}; operation.hEvent = event.value;
    BOOL ok = reading ? ReadFile(broker.value, bytes, size, count, &operation) :
        WriteFile(broker.value, bytes, size, count, &operation);
    if (!ok && GetLastError() == ERROR_IO_PENDING) {
      if (WaitForSingleObject(event.value, 4000) == WAIT_OBJECT_0)
        ok = GetOverlappedResult(broker.value, &operation, count, FALSE);
      else {
        CancelIoEx(broker.value, &operation);
        GetOverlappedResult(broker.value, &operation, count, TRUE);
        return false;
      }
    }
    return ok != FALSE;
  };
  std::string request;
  for (const wchar_t value : pipe_name) {
    if (value > 127) return 0;
    request.push_back(static_cast<char>(value));
  }
  request += '\n';
  DWORD count = 0;
  if (!transfer(false, request.data(), static_cast<DWORD>(request.size()), &count) || count != request.size()) return 0;
  char reply[32]{};
  std::string response;
  while (response.find('\n') == std::string::npos && response.size() < sizeof(reply)) {
    if (!transfer(true, reply, sizeof(reply), &count) || !count) return 0;
    response.append(reply, count);
  }
  char acknowledgement[] = "ACK\n";
  if (!transfer(false, acknowledgement, 4, &count) || count != 4) return 0;
  if(reply_out){*reply_out=response;return status.dwProcessId;}
  return response == "READY\n" ? status.dwProcessId : 0;
}
}

DesktopTunnel::DesktopTunnel() = default;
std::string DesktopTunnel::Protection(const std::string& action) {
  if(action!="enable"&&action!="disable"&&action!="status")return "ERROR";
  const std::string text="PROTECTION "+action;
  std::string reply;
  if(!ServiceSession(std::wstring(text.begin(),text.end()),&reply))return "UNAVAILABLE";
  if(!reply.empty()&&reply.back()=='\n')reply.pop_back();
  return reply;
}
DesktopTunnel::~DesktopTunnel() { Stop(); }
bool DesktopTunnel::Start(std::string config) {
  if (config.empty() || config.size() > 120 * 1024 || config.find('\n') != std::string::npos) return false;
  if (session_ && session_->running) return false;
  auto session = std::make_shared<Session>();
  session_ = session;
  std::thread([session, config = std::move(config)]() mutable {
    struct Done { std::shared_ptr<Session> s; ~Done() { s->running = false; } } done{session};
    BYTE random[16];
    if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) { session->Fail("ipc_failed"); return; }
    constexpr wchar_t hex[] = L"0123456789abcdef";
    std::wstring name = L"\\\\.\\pipe\\Viora-";
    for (BYTE value : random) { name += hex[value >> 4]; name += hex[value & 15]; }
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!PipeSecurity(&descriptor)) { session->Fail("ipc_failed"); return; }
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    Handle pipe;
    pipe.value = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 131072, 131072, 0, &security);
    LocalFree(descriptor);
    if (pipe.value == INVALID_HANDLE_VALUE) { session->Fail("ipc_failed"); return; }
    Handle event;
    event.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    OVERLAPPED connection{}; connection.hEvent = event.value;
    const BOOL connected = ConnectNamedPipe(pipe.value, &connection);
    const DWORD connection_error = connected ? ERROR_SUCCESS : GetLastError();
    if (!connected && connection_error != ERROR_IO_PENDING && connection_error != ERROR_PIPE_CONNECTED) { session->Fail("ipc_failed"); return; }
    if (connection_error == ERROR_PIPE_CONNECTED || connected) SetEvent(event.value);
    const auto cancel_connection = [&]() {
      CancelIoEx(pipe.value, &connection);
      DWORD ignored = 0;
      GetOverlappedResult(pipe.value, &connection, &ignored, TRUE);
    };
    const DWORD service_pid = ServiceSession(name);
    if (!service_pid) { cancel_connection(); session->Fail("service_unavailable"); return; }
    const DWORD wait = WaitForSingleObject(event.value, 20000);
    if (wait != WAIT_OBJECT_0) { cancel_connection(); session->Fail("helper_timeout"); return; }
    ULONG client = 0;
    if (!GetNamedPipeClientProcessId(pipe.value, &client) || client != service_pid) { session->Fail("ipc_identity"); return; }
    // Overlapped I/O also keeps a failed helper from blocking the UI or shutdown.
    const auto write = [&](const std::string& value) {
      OVERLAPPED operation{}; Handle ready; ready.value = CreateEventW(nullptr, TRUE, FALSE, nullptr); operation.hEvent = ready.value;
      DWORD count = 0;
      BOOL ok = WriteFile(pipe.value, value.data(), static_cast<DWORD>(value.size()), &count, &operation);
      if (!ok && GetLastError() == ERROR_IO_PENDING) {
        if (WaitForSingleObject(ready.value, 3000) == WAIT_OBJECT_0) ok = GetOverlappedResult(pipe.value, &operation, &count, FALSE);
        else { CancelIoEx(pipe.value, &operation); GetOverlappedResult(pipe.value, &operation, &count, TRUE); return false; }
      }
      return ok && count == value.size();
    };
    if (session->stop) { session->Emit("{\"state\":\"DISCONNECTED\"}"); return; }
    config += '\n';
    const bool written = write(config);
    SecureZeroMemory(config.data(), config.size()); config.clear();
    if (!written) { session->Fail("ipc_failed"); return; }
    std::string buffer;
    std::string disconnected;
    bool stop_sent = false;
    ULONGLONG stopping_at = 0;
    for (;;) {
      if (session->stop && !stop_sent) { write("{\"stop\":true}\n"); stop_sent = true; stopping_at = GetTickCount64(); }
      DWORD available = 0;
      if (!PeekNamedPipe(pipe.value, nullptr, 0, nullptr, &available, nullptr)) break;
      if (available) {
        char bytes[4096]; DWORD count = 0;
        OVERLAPPED operation{}; Handle ready; ready.value = CreateEventW(nullptr, TRUE, FALSE, nullptr); operation.hEvent = ready.value;
        BOOL ok = ReadFile(pipe.value, bytes, (std::min)(available, DWORD(sizeof(bytes))), &count, &operation);
        if (!ok && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(pipe.value, &operation, &count, TRUE);
        if (!ok || !count) break;
        buffer.append(bytes, count);
        if (buffer.size() > 32768) { session->Fail("ipc_failed"); return; }
        size_t end;
        while ((end = buffer.find('\n')) != std::string::npos) {
          const auto line = buffer.substr(0, end);
          if (line.find("DISCONNECTED") != std::string::npos) disconnected = line;
          else session->Emit(line);
          buffer.erase(0, end + 1);
        }
      }
      if (stop_sent && GetTickCount64() - stopping_at > 6000) { session->Fail("stop_timeout"); return; }
      Sleep(50);
    }
    // EOF is only a disconnect when the owner explicitly requested one.
    session->running = false;
    if (!disconnected.empty()) session->Emit(disconnected);
    else session->Fail(stop_sent ? "stop_unconfirmed" : "helper_exited");
  }).detach();
  return true;
}
void DesktopTunnel::Stop() {
  if (!session_) { session_ = std::make_shared<Session>(); session_->running = false; }
  if (session_->running) session_->stop = true;
  else session_->Emit("{\"state\":\"DISCONNECTED\"}");
}
std::string DesktopTunnel::Poll() {
  if (!session_) return "";
  std::lock_guard<std::mutex> lock(session_->mutex);
  std::string value; value.swap(session_->pending); return value;
}
