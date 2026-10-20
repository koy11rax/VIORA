#ifndef VIORA_DESKTOP_TRAY_H_
#define VIORA_DESKTOP_TRAY_H_
#include <flutter_linux/flutter_linux.h>
FlMethodChannel* register_viora_tray(FlView* view, GtkWindow* window);
#endif
