#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <sddl.h>
#include <string>

namespace {
int Dialog(const wchar_t* heading, const wchar_t* content, const wchar_t* button, bool chooseFolder = false) {
  TASKDIALOG_BUTTON actions[] = {{100, button}, {101, L"Выбрать папку…"}};
  TASKDIALOGCONFIG dialog{};
  dialog.cbSize = sizeof(dialog);
  dialog.hInstance = GetModuleHandleW(nullptr);
  dialog.dwFlags = TDF_USE_HICON_MAIN | TDF_SIZE_TO_CONTENT | TDF_ALLOW_DIALOG_CANCELLATION;
  dialog.hMainIcon = LoadIconW(dialog.hInstance, MAKEINTRESOURCEW(1));
  dialog.pszWindowTitle = L"VIORA";
  dialog.pszMainInstruction = heading;
  dialog.pszContent = content;
  dialog.pszFooter = L"VIORA " VIORA_SETUP_VERSION L" · Windows 10 / 11";
  dialog.dwCommonButtons = TDCBF_CANCEL_BUTTON;
  dialog.cButtons = chooseFolder ? 2 : 1; dialog.pButtons = actions; dialog.nDefaultButton = 100;
  int clicked = IDCANCEL;
  TaskDialogIndirect(&dialog, &clicked, nullptr, nullptr);
  return clicked;
}
bool Security(PSECURITY_DESCRIPTOR* descriptor) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD size = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::string bytes(size, '\0');
  const bool ok = GetTokenInformation(token, TokenUser, bytes.data(), size, &size) != FALSE;
  CloseHandle(token); if (!ok) return false;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid, &sid)) return false;
  std::wstring sddl = L"D:P(A;OICI;GA;;;SY)(A;OICI;GA;;;BA)(A;OICI;GA;;;" + std::wstring(sid) + L")";
  LocalFree(sid);
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, descriptor, nullptr) != FALSE;
}
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES}; InitCommonControlsEx(&controls);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  PWSTR defaultFolder = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, nullptr, &defaultFolder))) return 1;
  std::wstring installFolder = std::wstring(defaultFolder) + L"\\Viora";
  CoTaskMemFree(defaultFolder);
  while (true) {
    const std::wstring content = L"Папка приложения:\n" + installFolder + L"\n\nНа рабочем столе и в меню «Пуск» появится ярлык. Удалить VIORA можно через настройки Windows.\n\nСлужба VPN устанавливается в защищённую папку Program Files\\Viora\\Engine. Подтверди запрос администратора при установке — при подключении VPN повторное разрешение не потребуется.";
    const int choice = Dialog(L"Установить VIORA?", content.c_str(), L"Установить", true);
    if (choice == IDCANCEL) return 0;
    if (choice == 100) break;
    IFileOpenDialog* picker = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&picker)))) continue;
    picker->SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
    picker->SetTitle(L"Выбери папку для VIORA");
    if (SUCCEEDED(picker->Show(nullptr))) {
      IShellItem* item = nullptr;
      if (SUCCEEDED(picker->GetResult(&item))) {
        PWSTR selected = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &selected))) {
          std::wstring path(selected); CoTaskMemFree(selected);
          // Only local absolute paths. Reject command/property delimiters.
          if (path.size() >= 3 && path[1] == L':' && path[2] == L'\\' && path.find_first_of(L"\"\r\n") == std::wstring::npos) {
            while (!path.empty() && path.back() == L'\\') path.pop_back();
            const auto last = path.find_last_of(L'\\');
            if (_wcsicmp(path.substr(last == std::wstring::npos ? 0 : last + 1).c_str(), L"Viora") != 0) path += L"\\Viora";
            installFolder = path;
          } else {
            Dialog(L"Выбери локальную папку", L"Укажи папку на локальном диске компьютера.", L"Понятно");
          }
        }
        item->Release();
      }
    }
    picker->Release();
  }
  wchar_t temp[32768];
  const DWORD length = GetTempPathW(32768, temp);
  GUID guid{};
  if (!length || length >= 32768 || FAILED(CoCreateGuid(&guid))) return 1;
  wchar_t id[40]; StringFromGUID2(guid, id, 40);
  const std::wstring directory = std::wstring(temp) + L"Viora-Setup-" + id;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!Security(&descriptor)) return 1;
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  const bool created = CreateDirectoryW(directory.c_str(), &security) != FALSE;
  LocalFree(descriptor); if (!created) return 1;
  const std::wstring msi = directory + L"\\Viora.msi";
  const HRSRC resource = FindResourceW(instance, MAKEINTRESOURCEW(101), RT_RCDATA);
  const DWORD size = resource ? SizeofResource(instance, resource) : 0;
  const void* data = resource ? LockResource(LoadResource(instance, resource)) : nullptr;
  HANDLE file = CreateFileW(msi.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  DWORD written = 0;
  const bool saved = file != INVALID_HANDLE_VALUE && data && size && WriteFile(file, data, size, &written, nullptr) && written == size;
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  if (!saved) { DeleteFileW(msi.c_str()); RemoveDirectoryW(directory.c_str()); return 1; }
  wchar_t system[32768]; GetSystemDirectoryW(system, 32768);
  const std::wstring installer = std::wstring(system) + L"\\msiexec.exe";
  const std::wstring arguments = L"/i \"" + msi + L"\" /qb REBOOT=ReallySuppress INSTALLDIR=\"" + installFolder + L"\"";
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute); execute.fMask = SEE_MASK_NOCLOSEPROCESS;
  execute.lpFile = installer.c_str(); execute.lpParameters = arguments.c_str(); execute.nShow = SW_SHOWNORMAL;
  DWORD result = 1;
  if (ShellExecuteExW(&execute)) {
    WaitForSingleObject(execute.hProcess, INFINITE);
    GetExitCodeProcess(execute.hProcess, &result); CloseHandle(execute.hProcess);
  }
  DeleteFileW(msi.c_str()); RemoveDirectoryW(directory.c_str());
  if (result == 0 || result == 3010) {
    const auto message = result == 3010 ? L"VIORA установлена. Для завершения установки Windows рекомендует перезагрузку." : L"VIORA установлена. Подключи свою подписку и выбери сервер. Служба VPN готова: дополнительные запросы администратора при подключении не нужны.";
    if (Dialog(L"Готово", message, L"Открыть VIORA") == 100) {
      const std::wstring app = installFolder + L"\\Viora.exe";
      ShellExecuteW(nullptr, L"open", app.c_str(), nullptr, installFolder.c_str(), SW_SHOWNORMAL);
    }
  } else if (result != 1602) {
    Dialog(L"Установка не завершена", (L"Windows вернула код " + std::to_wstring(result) + L". Выбери «Выйти» в меню значка VIORA в трее и повтори установку.").c_str(), L"Закрыть");
  }
  CoUninitialize(); return static_cast<int>(result);
}
