#ifndef VIORA_SECURE_VAULT_H_
#define VIORA_SECURE_VAULT_H_
#include <optional>
#include <string>

class SecureVault {
 public:
  // Empty uses the current Windows user's LocalAppData directory.
  explicit SecureVault(std::wstring directory = L"");
  bool Read(const std::string& item, std::optional<std::string>* value);
  bool Write(const std::string& item, const std::string& value);
  bool Remove(const std::string& item);
  bool InstallationId(std::string* value);
 private:
  std::wstring directory_;
  bool Ready();
  std::wstring Path(const std::string& item);
};
#endif
