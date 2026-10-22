// Fixed WFP policy only. Never accepts addresses, paths, commands or filters
// from an unprivileged client. Used exclusively by the protected VIORA broker.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <fwpmu.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <sddl.h>
#include <cstdio>
#include <string>
#include <vector>
#include "policy_validation.h"

namespace {
const GUID provider = {0x56a10110,0x8102,0x4c71,{0x91,0x28,0x66,0x12,0x45,0x56,0x00,0x01}};
const GUID sublayer = {0x56a10111,0x8102,0x4c71,{0x91,0x28,0x66,0x12,0x45,0x56,0x00,0x01}};
GUID key(unsigned n) { GUID g=provider; g.Data1=0x56a10200+n; return g; }
struct Engine {
  HANDLE h=nullptr;
  ~Engine() { if(h) FwpmEngineClose0(h); }
};
struct Blob { FWP_BYTE_BLOB* p=nullptr; ~Blob(){if(p) FwpmFreeMemory0(reinterpret_cast<void**>(&p));} };
struct Descriptor { PSECURITY_DESCRIPTOR p=nullptr; ~Descriptor(){if(p)LocalFree(p);} };
bool check(DWORD value) { return value==ERROR_SUCCESS; }
bool remove_filters(HANDLE h) {
  FWPM_FILTER_ENUM_TEMPLATE0 query{}; query.providerKey=const_cast<GUID*>(&provider);
  query.flags=FWP_FILTER_ENUM_FLAG_INCLUDE_BOOTTIME|FWP_FILTER_ENUM_FLAG_INCLUDE_DISABLED;
  query.actionMask=0xffffffff;
  std::vector<UINT64> ids;
  bool ok=true;
  const GUID* layers[]={&FWPM_LAYER_ALE_AUTH_CONNECT_V4,&FWPM_LAYER_ALE_AUTH_CONNECT_V6,
    &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,&FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
    &FWPM_LAYER_OUTBOUND_IPPACKET_V4,&FWPM_LAYER_OUTBOUND_IPPACKET_V6,
    &FWPM_LAYER_IPFORWARD_V4,&FWPM_LAYER_IPFORWARD_V6};
  for(const auto* layer:layers) {
    query.layerKey=*layer;
    HANDLE enumeration=nullptr;
    if(!check(FwpmFilterCreateEnumHandle0(h,&query,&enumeration))) return false;
    for(;;) {
      FWPM_FILTER0** rows=nullptr; UINT32 count=0;
      if(!check(FwpmFilterEnum0(h,enumeration,256,&rows,&count))) {ok=false;break;}
      for(UINT32 i=0;i<count;++i) ids.push_back(rows[i]->filterId);
      if(rows) FwpmFreeMemory0(reinterpret_cast<void**>(&rows));
      if(count<256) break;
    }
    FwpmFilterDestroyEnumHandle0(h,enumeration);
    if(!ok)return false;
  }
  for(auto id:ids) if(!check(FwpmFilterDeleteById0(h,id))) ok=false;
  return ok;
}
bool add(HANDLE h,const GUID& layer,unsigned id,bool permit,UINT64 weight,
         std::vector<FWPM_FILTER_CONDITION0> conditions={},bool boot=false) {
  FWPM_FILTER0 f{};
  f.filterKey=key(id); f.providerKey=const_cast<GUID*>(&provider);
  f.displayData.name=const_cast<wchar_t*>(L"VIORA: постоянная защита");
  f.layerKey=layer; f.subLayerKey=sublayer;
  f.flags=boot?FWPM_FILTER_FLAG_BOOTTIME:FWPM_FILTER_FLAG_PERSISTENT;
  f.action.type=permit?FWP_ACTION_PERMIT:FWP_ACTION_BLOCK;
  f.weight.type=FWP_UINT64; f.weight.uint64=&weight;
  f.numFilterConditions=static_cast<UINT32>(conditions.size());
  f.filterCondition=conditions.data();
  return check(FwpmFilterAdd0(h,&f,nullptr,nullptr));
}
FWPM_FILTER_CONDITION0 number(const GUID& field,FWP_DATA_TYPE type,UINT32 n) {
  FWPM_FILTER_CONDITION0 c{};c.fieldKey=field;c.matchType=FWP_MATCH_EQUAL;c.conditionValue.type=type;
  if(type==FWP_UINT8)c.conditionValue.uint8=static_cast<UINT8>(n);
  else if(type==FWP_UINT16)c.conditionValue.uint16=static_cast<UINT16>(n);
  else c.conditionValue.uint32=n;
  return c;
}
bool install(HANDLE h,const std::wstring& directory) {
  FWPM_PROVIDER0 p{};p.providerKey=provider;p.flags=FWPM_PROVIDER_FLAG_PERSISTENT;
  p.displayData.name=const_cast<wchar_t*>(L"VIORA Lockdown");
  DWORD e=FwpmProviderAdd0(h,&p,nullptr);if(e!=ERROR_SUCCESS&&e!=FWP_E_ALREADY_EXISTS)return false;
  FWPM_SUBLAYER0 s{};s.subLayerKey=sublayer;s.providerKey=const_cast<GUID*>(&provider);
  s.flags=FWPM_SUBLAYER_FLAG_PERSISTENT;s.weight=0x8000;
  s.displayData.name=const_cast<wchar_t*>(L"VIORA Lockdown");
  e=FwpmSubLayerAdd0(h,&s,nullptr);if(e!=ERROR_SUCCESS&&e!=FWP_E_ALREADY_EXISTS)return false;
  if(!remove_filters(h))return false;
  Blob core,helper,dhcp;
  Descriptor system;
  if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:(A;;CC;;;SY)",SDDL_REVISION_1,&system.p,nullptr))return false;
  FWP_BYTE_BLOB sd{GetSecurityDescriptorLength(system.p),reinterpret_cast<UINT8*>(system.p)};
  FWPM_FILTER_CONDITION0 owner{};owner.fieldKey=FWPM_CONDITION_ALE_USER_ID;owner.matchType=FWP_MATCH_EQUAL;
  owner.conditionValue.type=FWP_SECURITY_DESCRIPTOR_TYPE;owner.conditionValue.sd=&sd;
  wchar_t sysdir[MAX_PATH];if(!GetSystemDirectoryW(sysdir,MAX_PATH))return false;
  if(!check(FwpmGetAppIdFromFileName0((std::wstring(sysdir)+L"\\svchost.exe").c_str(),&dhcp.p)))return false;
  if(!check(FwpmGetAppIdFromFileName0((directory+L"\\core\\xray.exe").c_str(),&core.p))||
     !check(FwpmGetAppIdFromFileName0((directory+L"\\viora_tunnel.exe").c_str(),&helper.p)))return false;
  UINT64 luid=0;
  MIB_IF_TABLE2* interfaces=nullptr;
  if(GetIfTable2(&interfaces)==NO_ERROR) {
    for(ULONG i=0;i<interfaces->NumEntries;++i)
      if(std::wstring(interfaces->Table[i].Alias)==L"viora0")luid=interfaces->Table[i].InterfaceLuid.Value;
    FreeMibTable(interfaces);
  }
  const GUID* layers[]={&FWPM_LAYER_ALE_AUTH_CONNECT_V4,&FWPM_LAYER_ALE_AUTH_CONNECT_V6,
                       &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,&FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6};
  for(unsigned i=0;i<4;++i) {
    const auto& layer=*layers[i];
    auto loop=number(FWPM_CONDITION_FLAGS,FWP_UINT32,FWP_CONDITION_FLAG_IS_LOOPBACK);
    loop.matchType=FWP_MATCH_FLAGS_ALL_SET;
    if(!add(h,layer,10+i*10,true,900,{loop}))return false;
    FWPM_FILTER_CONDITION0 app{};app.fieldKey=FWPM_CONDITION_ALE_APP_ID;
    app.matchType=FWP_MATCH_EQUAL;app.conditionValue.type=FWP_BYTE_BLOB_TYPE;app.conditionValue.byteBlob=core.p;
    if(!add(h,layer,11+i*10,true,800,{app,owner}))return false;
    if(luid) {
      FWPM_FILTER_CONDITION0 adapter{};adapter.fieldKey=FWPM_CONDITION_IP_LOCAL_INTERFACE;
      adapter.matchType=FWP_MATCH_EQUAL;adapter.conditionValue.type=FWP_UINT64;adapter.conditionValue.uint64=&luid;
      if(!add(h,layer,12+i*10,true,700,{adapter}))return false;
    }
    // IPv4 DHCP is infrastructure, not a general port exemption.
    if(i%2==0) {
      auto dhcpApp=app;dhcpApp.conditionValue.byteBlob=dhcp.p;
      if(!add(h,layer,13+i*10,true,600,{
        dhcpApp,
        number(FWPM_CONDITION_IP_PROTOCOL,FWP_UINT8,IPPROTO_UDP),
        number(FWPM_CONDITION_IP_LOCAL_PORT,FWP_UINT16,68),
        number(FWPM_CONDITION_IP_REMOTE_PORT,FWP_UINT16,67)}))return false;
      app.conditionValue.byteBlob=helper.p;
      // Only the helper may bootstrap server A records via this fixed DoH IP.
      if(!add(h,layer,14+i*10,true,600,{app,owner,
        number(FWPM_CONDITION_IP_REMOTE_ADDRESS,FWP_UINT32,0x01010101),
        number(FWPM_CONDITION_IP_PROTOCOL,FWP_UINT8,IPPROTO_TCP),
        number(FWPM_CONDITION_IP_REMOTE_PORT,FWP_UINT16,443)}))return false;
    }
    if(!add(h,layer,i,false,100))return false;
  }
  // Boot filters cover the interval before BFE loads the persistent ALE policy.
  return add(h,FWPM_LAYER_OUTBOUND_IPPACKET_V4,4,false,100,{},true)&&
         add(h,FWPM_LAYER_OUTBOUND_IPPACKET_V6,5,false,100,{},true)&&
         add(h,FWPM_LAYER_IPFORWARD_V4,6,false,100)&&
         add(h,FWPM_LAYER_IPFORWARD_V6,7,false,100);
}
int enabled(HANDLE h) {
  unsigned count=0;
  for(unsigned i=0;i<8;++i) {
    FWPM_FILTER0* f=nullptr;GUID k=key(i);
    DWORD e=FwpmFilterGetByKey0(h,&k,&f);
    if(e==ERROR_SUCCESS) {
      const bool valid = f && viora_firewall::expected_block_filter(*f, i, k, provider, sublayer);
      if(f)FwpmFreeMemory0(reinterpret_cast<void**>(&f));
      if(!valid)return -1;
      ++count;
    }
    else if(e!=FWP_E_FILTER_NOT_FOUND)return -1;
  }
  return count==8?1:count==0?0:-1;
}
}
int wmain(int argc,wchar_t** argv) {
  if(argc!=2||(wcscmp(argv[1],L"enable")&&wcscmp(argv[1],L"disable")&&wcscmp(argv[1],L"status")))return 2;
  Engine engine;
  if(!check(FwpmEngineOpen0(nullptr,RPC_C_AUTHN_WINNT,nullptr,nullptr,&engine.h)))return 3;
  if(!wcscmp(argv[1],L"status")) {
    int state=enabled(engine.h);puts(state==1?"ON":state==0?"OFF":"ERROR");return state<0?4:0;
  }
  wchar_t file[32768];DWORD size=GetModuleFileNameW(nullptr,file,32768);
  if(size==0||size>=32768)return 4;
  std::wstring directory(file,size);directory.resize(directory.find_last_of(L"\\"));
  if(!check(FwpmTransactionBegin0(engine.h,0)))return 5;
  bool on=!wcscmp(argv[1],L"enable");
  bool ok=on?install(engine.h,directory):remove_filters(engine.h);
  if(ok&&!on) {
    DWORD e=FwpmSubLayerDeleteByKey0(engine.h,&sublayer);
    ok=e==ERROR_SUCCESS||e==FWP_E_SUBLAYER_NOT_FOUND;
    if(ok){e=FwpmProviderDeleteByKey0(engine.h,&provider);ok=e==ERROR_SUCCESS||e==FWP_E_PROVIDER_NOT_FOUND;}
  }
  if(!ok){FwpmTransactionAbort0(engine.h);return 6;}
  if(!check(FwpmTransactionCommit0(engine.h)))return 7;
  // This directory is administrator protected. Clearing the policy through the
  // emergency/uninstall path must also clear its persistent account marker;
  // normal broker disable performs the same idempotent cleanup.
  if(!on && !DeleteFileW((directory+L"\\protection-owner.sid").c_str())) {
    const DWORD error=GetLastError();
    if(error!=ERROR_FILE_NOT_FOUND)return 8;
  }
  puts(on?"ON":"OFF");return 0;
}
