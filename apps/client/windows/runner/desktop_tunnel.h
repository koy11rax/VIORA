#pragma once
#include <memory>
#include <string>
class DesktopTunnel {
 public:
  DesktopTunnel();
  ~DesktopTunnel();
  bool Start(std::string config);
  void Stop();
  std::string Poll();
  static std::string Protection(const std::string& action);
 private:
  struct Session;
  std::shared_ptr<Session> session_;
};
