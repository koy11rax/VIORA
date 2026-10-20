#ifndef VIORA_PLATFORM_BRIDGE_H_
#define VIORA_PLATFORM_BRIDGE_H_
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> RegisterVioraPlatform(flutter::BinaryMessenger* messenger);
#endif
