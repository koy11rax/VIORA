#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Launching the shortcut again restores the existing tray session.
  HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, L"Local\\Viora.Client");
  const bool already_running = instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS;
  struct InstanceHandle { HANDLE value; ~InstanceHandle() { if (value) CloseHandle(value); } } instance_handle{instance_mutex};
  if (already_running) {
    HWND existing = nullptr;
    for (int attempt = 0; attempt < 100 && !existing; ++attempt) {
      existing = FindWindowW(L"VIORA_RUNNER_WIN32_WINDOW", L"Viora");
      if (!existing) Sleep(20);
    }
    if (existing) {
      DWORD process = 0;
      GetWindowThreadProcessId(existing, &process);
      AllowSetForegroundWindow(process);
      PostMessageW(existing, RegisterWindowMessageW(L"Viora.RestoreWindow"), 0, 0);
    }
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 840);
  if (!window.Create(L"Viora", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
