#include "secure_vault.h"
#include <windows.h>
#include <fstream>
#include <iostream>
#include <iterator>

#define CHECK(condition) do { if (!(condition)) { std::cerr << "Failed check at line " << __LINE__ << std::endl; return 1; } } while (false)
std::string bytes(const std::wstring& file) {
  std::ifstream input(file, std::ios::binary);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
int wmain(int argc, wchar_t* argv[]) {
  CHECK(argc == 2);
  wchar_t absolute[32768];
  CHECK(GetFullPathNameW(argv[1], 32768, absolute, nullptr) != 0);
  const std::wstring base(absolute);
  CHECK(base.find(L"\\artifacts") != std::wstring::npos);
  const auto directory = base + L"\\viora-vault-fixture-" + std::to_wstring(GetCurrentProcessId());
  CHECK(CreateDirectoryW(directory.c_str(), nullptr));
  SecureVault vault(directory);
  std::optional<std::string> value;
  CHECK(vault.Read("session", &value) && !value);
  std::string id, again;
  CHECK(vault.InstallationId(&id) && vault.InstallationId(&again) && id == again && id.size() == 32);
  CHECK(bytes(directory + L"\\installation.vault").find(id) == std::string::npos);
  const std::string fixture = "isolated-fixture-secret-never-a-real-session";
  CHECK(vault.Write("session", fixture));
  CHECK(vault.Read("session", &value) && value == fixture);
  CHECK(bytes(directory + L"\\session.vault").find(fixture) == std::string::npos);
  CHECK(vault.Write("profiles", "fixture-profile"));
  SecureVault reopened(directory);
  CHECK(reopened.Read("profiles", &value) && value == "fixture-profile");
  CHECK(!vault.Write("../escape", fixture));
  CHECK(!vault.Remove("../escape"));
  CHECK(!vault.Write("profiles", std::string(1048577, 'x')));
  auto corrupted = bytes(directory + L"\\session.vault");
  CHECK(!corrupted.empty());
  corrupted.back() ^= 1;
  { std::ofstream out(directory + L"\\session.vault", std::ios::binary); out.write(corrupted.data(), static_cast<std::streamsize>(corrupted.size())); }
  CHECK(!vault.Read("session", &value) && !value);
  CHECK(CopyFileW((directory + L"\\profiles.vault").c_str(), (directory + L"\\session.vault").c_str(), FALSE));
  CHECK(!vault.Read("session", &value) && !value); // Purpose binding rejects cross-item substitution.
  CHECK(vault.Remove("session") && vault.Remove("session"));
  CHECK(vault.Remove("profiles") && vault.Remove("installation"));
  CHECK(RemoveDirectoryW(directory.c_str()));
  std::cout << "Windows DPAPI fixture checks passed" << std::endl;
  return 0;
}
