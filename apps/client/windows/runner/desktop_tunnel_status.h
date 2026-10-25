#pragma once

#include <string>
#include <string_view>

// Tracks the final status from one authenticated helper pipe. An explicit
// failure already explains the end of the session; EOF must not replace it
// with a generic helper_exited error and trigger an unrelated retry.
class DesktopTunnelStatus {
 public:
  bool Consume(const std::string& line) {
    if (HasState(line, "DISCONNECTED")) {
      disconnected_ = line;
      return false;
    }
    if (HasState(line, "FAILED")) {
      terminal_failure_ = true;
      disconnected_.clear();
    }
    if (HasState(line, "CONNECTED") || HasState(line, "CONNECTING")) {
      terminal_failure_ = false;
      disconnected_.clear();
    }
    return true;
  }

  std::string Closed(bool stop_requested) const {
    if (!disconnected_.empty()) return disconnected_;
    if (terminal_failure_) return {};
    return std::string("{\"state\":\"FAILED\",\"code\":\"") +
        (stop_requested ? "stop_unconfirmed" : "helper_exited") + "\"}";
  }

 private:
  // The helper emits a flat JSON object with one state field. Accept JSON
  // whitespace too, without mistaking an error code containing FAILED for it.
  static bool HasState(const std::string& line, std::string_view state) {
    auto at = line.find("\"state\"");
    if (at == std::string::npos) return false;
    at += 7;
    const auto whitespace = [&]() {
      while (at < line.size() && (line[at] == ' ' || line[at] == '\t' ||
             line[at] == '\r' || line[at] == '\n')) ++at;
    };
    whitespace();
    if (at == line.size() || line[at++] != ':') return false;
    whitespace();
    if (at == line.size() || line[at++] != '"') return false;
    return line.compare(at, state.size(), state) == 0 &&
        at + state.size() < line.size() && line[at + state.size()] == '"';
  }

  bool terminal_failure_ = false;
  std::string disconnected_;
};
