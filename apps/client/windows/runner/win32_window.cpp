#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <algorithm>

#include "resource.h"

namespace {

// Let the parent handle resize edges even where Flutter covers the client area.
LRESULT CALLBACK ContentSubclass(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    HWND parent = GetParent(window);
    if (parent && !IsZoomed(parent)) {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(parent, &point);
      RECT rect;
      GetClientRect(parent, &rect);
      const int edge = MulDiv(6, GetDpiForWindow(parent), 96);
      if (point.x < edge || point.x >= rect.right - edge ||
          point.y >= rect.bottom - edge) return HTTRANSPARENT;
    }
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, ContentSubclass, id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"VIORA_RUNNER_WIN32_WINDOW";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  SetFrameTheme(frame_dark_);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam) return 0;
      break;
    case WM_NCACTIVATE:
      RedrawTitleBar();
      return TRUE;
    case WM_NCPAINT:
      return 0;
    case WM_NCHITTEST:
      return HitTestFrame(lparam);
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint;
      HDC dc = BeginPaint(hwnd, &paint);
      PaintTitleBar(dc);
      EndPaint(hwnd, &paint);
      return 0;
    }
    case WM_PRINTCLIENT:
      PaintTitleBar(reinterpret_cast<HDC>(wparam));
      return 0;
    case WM_NCMOUSEMOVE: {
      const int hit = HitTestFrame(lparam);
      const int hover = (hit == HTMINBUTTON || hit == HTMAXBUTTON || hit == HTCLOSE) ? hit : 0;
      if (hover_button_ != hover) {
        hover_button_ = hover;
        RedrawTitleBar();
      }
      TRACKMOUSEEVENT tracking = {sizeof(TRACKMOUSEEVENT), TME_LEAVE | TME_NONCLIENT, hwnd, 0};
      TrackMouseEvent(&tracking);
      break;
    }
    case WM_NCMOUSELEAVE:
      hover_button_ = 0;
      RedrawTitleBar();
      return 0;
    case WM_NCLBUTTONDOWN:
      if (wparam == HTMINBUTTON || wparam == HTMAXBUTTON || wparam == HTCLOSE) {
        pressed_button_ = static_cast<int>(wparam);
        SetCapture(hwnd);
        RedrawTitleBar();
        return 0;
      }
      break;
    case WM_LBUTTONUP:
    case WM_NCLBUTTONUP:
      if (pressed_button_) {
        POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        if (message == WM_LBUTTONUP) ClientToScreen(hwnd, &point);
        const int hit = HitTestFrame(MAKELPARAM(point.x, point.y));
        const int pressed = pressed_button_;
        pressed_button_ = 0;
        ReleaseCapture();
        RedrawTitleBar();
        if (hit == pressed) {
          const WPARAM command = pressed == HTCLOSE ? SC_CLOSE :
              pressed == HTMINBUTTON ? SC_MINIMIZE :
              IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE;
          PostMessage(hwnd, WM_SYSCOMMAND, command, 0);
        }
        return 0;
      }
      break;
    case WM_CAPTURECHANGED:
      pressed_button_ = 0;
      RedrawTitleBar();
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RedrawTitleBar();
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      SetFrameTheme(frame_dark_);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ContentSubclass, 1, 0);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  frame.top = std::min<LONG>(FrameHeight(), frame.bottom);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

int Win32Window::FrameHeight() const {
  return MulDiv(38, GetDpiForWindow(window_handle_), 96);
}

void Win32Window::RedrawTitleBar() {
  RECT bar;
  GetClientRect(window_handle_, &bar);
  bar.bottom = FrameHeight();
  InvalidateRect(window_handle_, &bar, FALSE);
}

void Win32Window::SetFrameTheme(bool dark) {
  frame_dark_ = dark;
  if (!window_handle_) return;
  BOOL enabled = dark;
  DwmSetWindowAttribute(window_handle_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                       &enabled, sizeof(enabled));
  RedrawTitleBar();
}

int Win32Window::HitTestFrame(LPARAM position) {
  POINT point = {GET_X_LPARAM(position), GET_Y_LPARAM(position)};
  ScreenToClient(window_handle_, &point);
  RECT rect;
  GetClientRect(window_handle_, &rect);
  const int dpi = static_cast<int>(GetDpiForWindow(window_handle_));
  const int edge = MulDiv(6, dpi, 96);
  if (!IsZoomed(window_handle_)) {
    const bool left = point.x < edge;
    const bool right = point.x >= rect.right - edge;
    const bool top = point.y < edge;
    const bool bottom = point.y >= rect.bottom - edge;
    if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
    if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
  }
  if (point.y < FrameHeight()) {
    const int width = MulDiv(46, dpi, 96);
    if (point.x >= rect.right - width) return HTCLOSE;
    if (point.x >= rect.right - 2 * width) return HTMAXBUTTON;
    if (point.x >= rect.right - 3 * width) return HTMINBUTTON;
    return HTCAPTION;
  }
  return HTCLIENT;
}

void Win32Window::PaintTitleBar(HDC dc) {
  RECT bar;
  GetClientRect(window_handle_, &bar);
  bar.bottom = FrameHeight();
  const int dpi = static_cast<int>(GetDpiForWindow(window_handle_));
  auto scale = [dpi](int value) { return MulDiv(value, dpi, 96); };
  const COLORREF background = frame_dark_ ? RGB(29,27,37) : RGB(255,255,255);
  const COLORREF foreground = frame_dark_ ? RGB(180,171,197) : RGB(101,92,118);
  HBRUSH brush = CreateSolidBrush(background);
  FillRect(dc, &bar, brush);
  DeleteObject(brush);
  const int saved = SaveDC(dc);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, foreground);
  HFONT font = CreateFontW(-scale(12), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  SelectObject(dc, font);
  RECT text = bar;
  text.left = scale(18);
  text.right -= scale(138);
  DrawTextW(dc, L"VIORA", -1, &text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  for (int i = 0; i < 3; ++i) {
    const int hit = i == 0 ? HTMINBUTTON : i == 1 ? HTMAXBUTTON : HTCLOSE;
    RECT button = {bar.right - scale(46) * (3-i), 0,
                   bar.right - scale(46) * (2-i), bar.bottom - 1};
    const bool hover = hover_button_ == hit || pressed_button_ == hit;
    if (hover) {
      brush = CreateSolidBrush(hit == HTCLOSE ? RGB(196,43,64) :
          frame_dark_ ? RGB(52,45,66) : RGB(237,232,245));
      FillRect(dc, &button, brush);
      DeleteObject(brush);
    }
    HPEN pen = CreatePen(PS_SOLID, std::max(1, scale(1)),
        hover && hit == HTCLOSE ? RGB(255,255,255) : foreground);
    HGDIOBJ old_pen = SelectObject(dc, pen);
    HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    const int x = (button.left + button.right)/2 - scale(5);
    const int y = bar.bottom/2 - scale(5);
    if (i == 0) {
      MoveToEx(dc, x, y + scale(5), nullptr);
      LineTo(dc, x + scale(10), y + scale(5));
    } else if (i == 1) {
      if (IsZoomed(window_handle_)) {
        Rectangle(dc, x + scale(3), y, x + scale(10), y + scale(7));
        HBRUSH cover = CreateSolidBrush(hover ? (frame_dark_ ? RGB(52,45,66) : RGB(237,232,245)) : background);
        RECT overlap = {x, y + scale(3), x + scale(7), y + scale(10)};
        FillRect(dc, &overlap, cover);
        DeleteObject(cover);
        Rectangle(dc, overlap.left, overlap.top, overlap.right, overlap.bottom);
      } else {
        Rectangle(dc, x, y, x + scale(10), y + scale(10));
      }
    } else {
      MoveToEx(dc, x, y, nullptr);
      LineTo(dc, x + scale(10), y + scale(10));
      MoveToEx(dc, x + scale(10), y, nullptr);
      LineTo(dc, x, y + scale(10));
    }
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(pen);
  }
  HPEN border = CreatePen(PS_SOLID, 1, frame_dark_ ? RGB(60,53,75) : RGB(222,216,233));
  SelectObject(dc, border);
  MoveToEx(dc, 0, bar.bottom - 1, nullptr);
  LineTo(dc, bar.right, bar.bottom - 1);
  RestoreDC(dc, saved);
  DeleteObject(border);
  DeleteObject(font);
}
