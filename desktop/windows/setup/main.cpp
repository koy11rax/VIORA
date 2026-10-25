#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <sddl.h>
#include <string>

namespace {
int Dialog(const wchar_t* heading, const wchar_t* content, const wchar_t* button, const wchar_t* additionalButton = nullptr) {
  TASKDIALOG_BUTTON actions[] = {{100, button}, {101, additionalButton}};
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
  dialog.cButtons = additionalButton ? 2 : 1; dialog.pButtons = actions; dialog.nDefaultButton = 100;
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
bool PrivateDirectory(const std::wstring& path, PSECURITY_DESCRIPTOR descriptor, bool protectExisting) {
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  if (CreateDirectoryW(path.c_str(), &security)) return true;
  if (GetLastError() != ERROR_ALREADY_EXISTS) return false;
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return false;
  if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    SetLastError(ERROR_ACCESS_DENIED);
    return false;
  }
  // Existing application data may have inherited a broader DACL. The log
  // directory itself must use only the current user, SYSTEM and Administrators.
  return !protectExisting || SetFileSecurityW(path.c_str(),
    DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor) != FALSE;
}
bool PrepareLog(std::wstring* path) {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
    SetLastError(ERROR_PATH_NOT_FOUND);
    return false;
  }
  const std::wstring appDirectory = std::wstring(local) + L"\\Viora";
  CoTaskMemFree(local);
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!Security(&descriptor)) return false;
  const std::wstring directory = appDirectory + L"\\installer-logs";
  const bool ready = PrivateDirectory(appDirectory, descriptor, true) &&
    PrivateDirectory(directory, descriptor, true);
  if (!ready) {
    const DWORD error = GetLastError();
    LocalFree(descriptor);
    SetLastError(error);
    return false;
  }
  GUID guid{};
  wchar_t id[40]{};
  if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, id, 40)) {
    LocalFree(descriptor);
    SetLastError(ERROR_GEN_FAILURE);
    return false;
  }
  const std::wstring candidate = directory + L"\\Viora-Setup-" + id + L".log";
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  // Reserve an unpredictable filename before elevation. CREATE_NEW refuses
  // replacement of an existing file/link, and the private DACL survives MSI use.
  HANDLE file = CreateFileW(candidate.c_str(), GENERIC_WRITE, 0, &security,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  const DWORD error = GetLastError();
  LocalFree(descriptor);
  if (file == INVALID_HANDLE_VALUE) {
    SetLastError(error);
    return false;
  }
  CloseHandle(file);
  *path = candidate;
  return true;
}
void FailureDialog(DWORD result, const std::wstring& log, bool installerReported) {
  const std::wstring content = (installerReported
    ? L"Windows Installer не завершил установку. Код: "
    : L"Windows не смогла запустить установщик или подтвердить его завершение. Код: ") +
    std::to_wstring(result) + L".\n\nЖурнал установки сохранён:\n" + log +
    L"\n\nОткрой журнал, чтобы узнать причину ошибки. Он остаётся только на этом компьютере.";
  if (Dialog(L"Установка не завершена", content.c_str(), L"Открыть журнал") == 100) {
    wchar_t system[32768]{};
    const UINT length = GetSystemDirectoryW(system, 32768);
    if (length && length < 32768) {
      const std::wstring editor = std::wstring(system) + L"\\notepad.exe";
      const std::wstring arguments = L"\"" + log + L"\"";
      // Open only the selected local log in a fixed system editor. No upload,
      // shell command or user-controlled executable is involved.
      if (reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", editor.c_str(),
          arguments.c_str(), nullptr, SW_SHOWNORMAL)) > 32) return;
    }
    Dialog(L"Журнал не удалось открыть", (L"Открой этот файл вручную:\n" + log).c_str(), L"Закрыть");
  }
}
int BootstrapFailure(DWORD result, const char* step, const std::wstring& log) {
  if (!result) result = ERROR_GEN_FAILURE;
  // Before MSI starts, its reserved log is still empty. Record only a fixed
  // bootstrap stage and numeric Windows error; never installation/profile data.
  HANDLE file = CreateFileW(log.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    const std::string summary = "VIORA bootstrap failure\r\nstage=" + std::string(step) +
      "\r\nwin32_error=" + std::to_string(result) + "\r\n";
    DWORD written = 0;
    WriteFile(file, summary.data(), static_cast<DWORD>(summary.size()), &written, nullptr);
    CloseHandle(file);
  }
  FailureDialog(result, log, false);
  return static_cast<int>(result);
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
    const int choice = Dialog(L"Установить VIORA?", content.c_str(), L"Установить", L"Выбрать папку…");
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
  std::wstring log;
  if (!PrepareLog(&log)) {
    const DWORD error = GetLastError();
    Dialog(L"Не удалось создать журнал установки", (L"Проверь доступ к личной папке AppData\\Local\\Viora\\installer-logs и свободное место на диске. Код Windows: " + std::to_wstring(error) + L". Установка не запускалась.").c_str(), L"Закрыть");
    return static_cast<int>(error ? error : ERROR_ACCESS_DENIED);
  }
  wchar_t temp[32768];
  const DWORD length = GetTempPathW(32768, temp);
  GUID guid{};
  if (!length || length >= 32768) return BootstrapFailure(ERROR_PATH_NOT_FOUND, "temp_path", log);
  if (FAILED(CoCreateGuid(&guid))) return BootstrapFailure(ERROR_GEN_FAILURE, "temp_id", log);
  wchar_t id[40]; StringFromGUID2(guid, id, 40);
  const std::wstring directory = std::wstring(temp) + L"Viora-Setup-" + id;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!Security(&descriptor)) return BootstrapFailure(GetLastError(), "temp_security", log);
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  const bool created = CreateDirectoryW(directory.c_str(), &security) != FALSE;
  const DWORD createError = GetLastError();
  LocalFree(descriptor);
  if (!created) return BootstrapFailure(createError, "temp_directory", log);
  const std::wstring msi = directory + L"\\Viora.msi";
  const HRSRC resource = FindResourceW(instance, MAKEINTRESOURCEW(101), RT_RCDATA);
  const DWORD size = resource ? SizeofResource(instance, resource) : 0;
  const void* data = resource ? LockResource(LoadResource(instance, resource)) : nullptr;
  HANDLE file = CreateFileW(msi.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  DWORD written = 0;
  const bool saved = file != INVALID_HANDLE_VALUE && data && size && WriteFile(file, data, size, &written, nullptr) && written == size;
  const DWORD saveError = GetLastError();
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  if (!saved) {
    DeleteFileW(msi.c_str()); RemoveDirectoryW(directory.c_str());
    return BootstrapFailure(saveError, "msi_payload", log);
  }
  wchar_t system[32768]{};
  const UINT systemLength = GetSystemDirectoryW(system, 32768);
  if (!systemLength || systemLength >= 32768) {
    const DWORD error = GetLastError();
    DeleteFileW(msi.c_str()); RemoveDirectoryW(directory.c_str());
    return BootstrapFailure(error, "system_directory", log);
  }
  const std::wstring installer = std::wstring(system) + L"\\msiexec.exe";
  const std::wstring arguments = L"/i \"" + msi + L"\" /qb /L*V \"" + log + L"\" REBOOT=ReallySuppress INSTALLDIR=\"" + installFolder + L"\"";
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute); execute.fMask = SEE_MASK_NOCLOSEPROCESS;
  execute.lpFile = installer.c_str(); execute.lpParameters = arguments.c_str(); execute.nShow = SW_SHOWNORMAL;
  DWORD result = ERROR_INSTALL_FAILURE;
  bool installerReported = false;
  bool installerStarted = false;
  if (ShellExecuteExW(&execute)) {
    installerStarted = true;
    if (execute.hProcess) {
      // Let Windows Installer finish its own rollback. A bootstrapper timeout
      // must never kill msiexec or interrupt an in-progress transaction.
      if (WaitForSingleObject(execute.hProcess, INFINITE) == WAIT_OBJECT_0) {
        installerReported = GetExitCodeProcess(execute.hProcess, &result) != FALSE;
        if (!installerReported) result = GetLastError();
      } else {
        result = GetLastError();
      }
      CloseHandle(execute.hProcess);
    } else {
      result = ERROR_INVALID_HANDLE;
    }
  } else {
    result = GetLastError();
  }
  if (!installerStarted || installerReported) {
    DeleteFileW(msi.c_str()); RemoveDirectoryW(directory.c_str());
  }
  if (installerReported && (result == 0 || result == 3010)) {
    const auto message = result == 3010 ? L"VIORA установлена. Для завершения установки Windows рекомендует перезагрузку." : L"VIORA установлена. Подключи свою подписку и выбери сервер. Служба VPN готова: дополнительные запросы администратора при подключении не нужны.";
    if (Dialog(L"Готово", message, L"Открыть VIORA") == 100) {
      const std::wstring app = installFolder + L"\\Viora.exe";
      ShellExecuteW(nullptr, L"open", app.c_str(), nullptr, installFolder.c_str(), SW_SHOWNORMAL);
    }
  } else if (result != 1602) {
    if (!installerStarted) return BootstrapFailure(result, "msiexec_launch", log);
    FailureDialog(result, log, installerReported);
  }
  CoUninitialize(); return static_cast<int>(result);
}
