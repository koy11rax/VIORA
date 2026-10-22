#include "policy_validation.h"
#include <cstdio>

#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "Failed check at line %d\n", __LINE__); return 1; } } while (false)

int main() {
  // Only in-memory WFP structs are used. The test never opens a WFP engine,
  // queries installed filters, changes firewall state, or requires elevation.
  const GUID provider = {0x56a10110, 0x8102, 0x4c71, {0x91, 0x28, 0x66, 0x12, 0x45, 0x56, 0, 1}};
  const GUID sublayer = {0x56a10111, 0x8102, 0x4c71, {0x91, 0x28, 0x66, 0x12, 0x45, 0x56, 0, 1}};
  const GUID* layers[] = {
      &FWPM_LAYER_ALE_AUTH_CONNECT_V4, &FWPM_LAYER_ALE_AUTH_CONNECT_V6,
      &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4, &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
      &FWPM_LAYER_OUTBOUND_IPPACKET_V4, &FWPM_LAYER_OUTBOUND_IPPACKET_V6,
      &FWPM_LAYER_IPFORWARD_V4, &FWPM_LAYER_IPFORWARD_V6};
  UINT64 weight = 100;
  for (unsigned id = 0; id < 8; ++id) {
    GUID key = provider; key.Data1 = 0x56a10200 + id;
    FWPM_FILTER0 valid{};
    valid.filterKey = key;
    valid.providerKey = const_cast<GUID*>(&provider);
    valid.subLayerKey = sublayer;
    valid.layerKey = *layers[id];
    valid.action.type = FWP_ACTION_BLOCK;
    valid.flags = id == 4 || id == 5 ? FWPM_FILTER_FLAG_BOOTTIME : FWPM_FILTER_FLAG_PERSISTENT;
    valid.weight.type = FWP_UINT64; valid.weight.uint64 = &weight;
    const auto accepts = [&](const FWPM_FILTER0& filter) {
      return viora_firewall::expected_block_filter(filter, id, key, provider, sublayer);
    };
    CHECK(accepts(valid));
    auto altered = valid; altered.action.type = FWP_ACTION_PERMIT; CHECK(!accepts(altered));
    altered = valid; altered.flags |= FWPM_FILTER_FLAG_DISABLED; CHECK(!accepts(altered));
    altered = valid; altered.flags = 0; CHECK(!accepts(altered));
    altered = valid; altered.layerKey = *layers[(id + 1) % 8]; CHECK(!accepts(altered));
    altered = valid; altered.providerKey = nullptr; CHECK(!accepts(altered));
    altered = valid; altered.providerKey = const_cast<GUID*>(&sublayer); CHECK(!accepts(altered));
    altered = valid; altered.subLayerKey = provider; CHECK(!accepts(altered));
    altered = valid; altered.filterKey = provider; CHECK(!accepts(altered));
    altered = valid; altered.numFilterConditions = 1; CHECK(!accepts(altered));
    altered = valid; altered.weight.type = FWP_EMPTY; CHECK(!accepts(altered));
    altered = valid; altered.weight.uint64 = nullptr; CHECK(!accepts(altered));
    UINT64 wrong_weight = 99;
    altered = valid; altered.weight.uint64 = &wrong_weight; CHECK(!accepts(altered));
    CHECK(!viora_firewall::expected_block_filter(valid, 8, key, provider, sublayer));
  }
  std::puts("WFP block filter validation fixtures passed (8 layers, 104 negative cases)");
  return 0;
}
