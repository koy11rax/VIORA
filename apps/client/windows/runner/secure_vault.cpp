#include "secure_vault.h"
#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>
#include <shlobj.h>
#include <vector>

namespace {
constexpr size_t kMaxValue = 1048576;
bool ValidItem(const std::string& item) {
  return item == "session" || item == "profiles" || item == "installation";
}
std::string RandomId() {
  unsigned char bytes[16];
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return {};
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  for (auto byte : bytes) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  SecureZeroMemory(bytes, sizeof(bytes));
  return result;
}
}

SecureVault::SecureVault(std::wstring directory) : directory_(std::move(directory)) {}
bool SecureVault::Ready() {
  if (directory_.empty()) {
    PWSTR local = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local))) return false;
    directory_ = std::wstring(local) + L"\\viora";
    CoTaskMemFree(local);
    if (!CreateDirectoryW(directory_.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
    directory_ += L"\\vault";
  }
  if (!CreateDirectoryW(directory_.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
  const DWORD attributes = GetFileAttributesW(directory_.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}
std::wstring SecureVault::Path(const std::string& item) {
  return directory_ + L"\\" + std::wstring(item.begin(), item.end()) + L".vault";
}
bool SecureVault::Read(const std::string& item, std::optional<std::string>* value) {
  value->reset();
  if (!ValidItem(item) || !Ready()) return false;
  HANDLE file = CreateFileW(Path(item).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
  LARGE_INTEGER size;
  bool valid = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= static_cast<LONGLONG>(kMaxValue + 16384);
  std::vector<BYTE> encrypted(valid ? static_cast<size_t>(size.QuadPart) : 0);
  DWORD read = 0;
  valid = valid && ReadFile(file, encrypted.data(), static_cast<DWORD>(encrypted.size()), &read, nullptr) && read == encrypted.size();
  CloseHandle(file);
  if (!valid) return false;
  const std::string purpose = "Viora/vault/v1/" + item;
  DATA_BLOB input{static_cast<DWORD>(encrypted.size()), encrypted.data()};
  DATA_BLOB entropy{static_cast<DWORD>(purpose.size()), reinterpret_cast<BYTE*>(const_cast<char*>(purpose.data()))};
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) return false;
  valid = output.cbData <= kMaxValue;
  if (valid) *value = std::string(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return valid;
}
bool SecureVault::Write(const std::string& item, const std::string& value) {
  if (!ValidItem(item) || value.empty() || value.size() > kMaxValue || !Ready()) return false;
  const std::string purpose = "Viora/vault/v1/" + item;
  DATA_BLOB input{static_cast<DWORD>(value.size()), reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
  DATA_BLOB entropy{static_cast<DWORD>(purpose.size()), reinterpret_cast<BYTE*>(const_cast<char*>(purpose.data()))};
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"Viora", &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) return false;
  const std::string nonce = RandomId();
  if (nonce.empty()) { LocalFree(output.pbData); return false; }
  const std::wstring temporary = Path(item) + L"." + std::wstring(nonce.begin(), nonce.end()) + L".tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
  bool saved = false;
  if (file != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    saved = WriteFile(file, output.pbData, output.cbData, &written, nullptr) && written == output.cbData && FlushFileBuffers(file);
    CloseHandle(file);
    if (saved) saved = MoveFileExW(temporary.c_str(), Path(item).c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
  }
  if (!saved) DeleteFileW(temporary.c_str());
  LocalFree(output.pbData);
  return saved;
}
bool SecureVault::Remove(const std::string& item) {
  if (!ValidItem(item) || !Ready()) return false;
  return DeleteFileW(Path(item).c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND;
}
bool SecureVault::InstallationId(std::string* value) {
  std::optional<std::string> saved;
  if (!Read("installation", &saved)) return false;
  if (saved) {
    if (saved->size() != 32 || saved->find_first_not_of("0123456789abcdef") != std::string::npos) return false;
    *value = *saved;
    return true;
  }
  *value = RandomId();
  return !value->empty() && Write("installation", *value);
}
