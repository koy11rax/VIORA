cmake_minimum_required(VERSION 3.20)
project(VioraTunnelStatusTests LANGUAGES CXX)

include(CTest)
add_executable(viora_tunnel_status_test tunnel_status_test.cpp)
target_compile_features(viora_tunnel_status_test PRIVATE cxx_std_17)
target_include_directories(viora_tunnel_status_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../apps/client/windows/runner")
if(MSVC)
  target_compile_options(viora_tunnel_status_test PRIVATE /W4 /WX /utf-8)
endif()
add_test(NAME tunnel_status_eof COMMAND viora_tunnel_status_test)
