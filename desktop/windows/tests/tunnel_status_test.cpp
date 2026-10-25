#include "desktop_tunnel_status.h"
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "Failed check at line %d\n", __LINE__); return 1; } } while (false)

namespace {
std::vector<std::string> ReadFixture(const std::string& bytes, bool stopping = false) {
  // Use the production status tracker with a fake helper stream. No service,
  // named pipe, engine, network, firewall, or elevation is involved.
  DesktopTunnelStatus status;
  std::istringstream input(bytes);
  std::vector<std::string> events;
  std::string line;
  while (std::getline(input, line)) {
    if (status.Consume(line)) events.push_back(line);
  }
  const auto end = status.Closed(stopping);
  if (!end.empty()) events.push_back(end);
  return events;
}
}

int main() {
  const std::string failure = "{\"state\":\"FAILED\",\"code\":\"core_integrity\"}";
  const std::string connecting = "{\"state\":\"CONNECTING\"}";
  const std::string connected = "{\"state\":\"CONNECTED\"}";
  const std::string disconnected = "{\"state\":\"DISCONNECTED\"}";
  const std::string unexpected = "{\"state\":\"FAILED\",\"code\":\"helper_exited\"}";
  const std::string unconfirmed = "{\"state\":\"FAILED\",\"code\":\"stop_unconfirmed\"}";

  CHECK(ReadFixture(failure + "\n") == std::vector<std::string>{failure});
  CHECK(ReadFixture(failure + "\n", true) == std::vector<std::string>{failure});
  CHECK(ReadFixture(connecting + "\n" + failure + "\n") ==
        (std::vector<std::string>{connecting, failure}));
  CHECK(ReadFixture(connected + "\n" + failure + "\n") ==
        (std::vector<std::string>{connected, failure}));
  CHECK(ReadFixture(connected + "\n") ==
        (std::vector<std::string>{connected, unexpected}));
  CHECK(ReadFixture(connecting + "\n") ==
        (std::vector<std::string>{connecting, unexpected}));
  CHECK(ReadFixture(connected + "\n", true) ==
        (std::vector<std::string>{connected, unconfirmed}));
  CHECK(ReadFixture("") == std::vector<std::string>{unexpected});
  CHECK(ReadFixture("", true) == std::vector<std::string>{unconfirmed});
  CHECK(ReadFixture(connected + "\n" + disconnected + "\n", true) ==
        (std::vector<std::string>{connected, disconnected}));
  CHECK(ReadFixture(failure + "\n" + connected + "\n") ==
        (std::vector<std::string>{failure, connected, unexpected}));
  CHECK(ReadFixture(failure + "\n" + connecting + "\n") ==
        (std::vector<std::string>{failure, connecting, unexpected}));
  const std::string spaced = "{ \"code\": \"core_integrity\", \"state\" : \"FAILED\" }";
  CHECK(ReadFixture(spaced + "\r\n") == std::vector<std::string>{spaced + "\r"});
  const std::string not_failure = "{\"state\":\"CONNECTED\",\"code\":\"FAILED\"}";
  CHECK(ReadFixture(not_failure + "\n") ==
        (std::vector<std::string>{not_failure, unexpected}));
  const std::string malformed = "{\"state\":\"FAILED_SUFFIX\"}";
  CHECK(ReadFixture(malformed + "\n") ==
        (std::vector<std::string>{malformed, unexpected}));
  CHECK(ReadFixture(failure + "\n" + failure + "\n") ==
        (std::vector<std::string>{failure, failure}));
  CHECK(ReadFixture(disconnected + "\n" + connected + "\n") ==
        (std::vector<std::string>{connected, unexpected}));
  CHECK(ReadFixture(disconnected + "\n" + failure + "\n") ==
        std::vector<std::string>{failure});

  std::puts("Tunnel status EOF fixtures passed (18 scenarios)");
  return 0;
}
