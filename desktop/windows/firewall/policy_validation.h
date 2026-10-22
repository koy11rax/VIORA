#pragma once

#include <winsock2.h>
#include <windows.h>
#include <fwpmu.h>

namespace viora_firewall {
// Pure validation only: no WFP calls or changes. Presence of a filter GUID
// does not prove its action still blocks or that it applies to the right layer.
inline bool expected_block_filter(const FWPM_FILTER0& filter, unsigned id,
                                  const GUID& filter_key, const GUID& provider,
                                  const GUID& sublayer) {
  const GUID* layers[] = {
      &FWPM_LAYER_ALE_AUTH_CONNECT_V4, &FWPM_LAYER_ALE_AUTH_CONNECT_V6,
      &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4, &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
      &FWPM_LAYER_OUTBOUND_IPPACKET_V4, &FWPM_LAYER_OUTBOUND_IPPACKET_V6,
      &FWPM_LAYER_IPFORWARD_V4, &FWPM_LAYER_IPFORWARD_V6};
  if (id >= 8) return false;
  const UINT32 flags = id == 4 || id == 5 ? FWPM_FILTER_FLAG_BOOTTIME
                                         : FWPM_FILTER_FLAG_PERSISTENT;
  return IsEqualGUID(filter.filterKey, filter_key) && filter.providerKey &&
         IsEqualGUID(*filter.providerKey, provider) &&
         IsEqualGUID(filter.subLayerKey, sublayer) &&
         IsEqualGUID(filter.layerKey, *layers[id]) &&
         filter.action.type == FWP_ACTION_BLOCK && filter.flags == flags &&
         filter.numFilterConditions == 0 && filter.weight.type == FWP_UINT64 &&
         filter.weight.uint64 && *filter.weight.uint64 == 100;
}
}  // namespace viora_firewall
