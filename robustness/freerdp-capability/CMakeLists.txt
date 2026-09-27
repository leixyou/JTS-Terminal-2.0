cmake_minimum_required(VERSION 3.24)

project(JTSFreeRDPCapabilityRobustness LANGUAGES C CXX)

if(NOT DEFINED JTS_FREERDP_SOURCE_DIR)
  message(FATAL_ERROR "JTS_FREERDP_SOURCE_DIR must point to the pinned FreeRDP source tree")
endif()

if(NOT IS_DIRECTORY "${JTS_FREERDP_SOURCE_DIR}/libfreerdp/core")
  message(FATAL_ERROR "JTS_FREERDP_SOURCE_DIR is not a FreeRDP source tree: ${JTS_FREERDP_SOURCE_DIR}")
endif()

# FreeRDP's upstream input-test configuration instruments every static
# dependency. The final JTS target links the LLVM input runtime once through the
# upstream config target, while the caller supplies ASan/UBSan flags to the whole
# build.
set(BUILD_FUZZERS ON CACHE BOOL "Build FreeRDP mutation targets" FORCE)
add_subdirectory("${JTS_FREERDP_SOURCE_DIR}" freerdp)

add_executable(
  jts-freerdp-capability-robustness
  FreeRDPCapabilityRobustness.c
)

target_compile_features(jts-freerdp-capability-robustness PRIVATE c_std_11)
target_include_directories(
  jts-freerdp-capability-robustness
  PRIVATE
    "${JTS_FREERDP_SOURCE_DIR}/include"
    "${JTS_FREERDP_SOURCE_DIR}/libfreerdp/core"
    "${JTS_FREERDP_SOURCE_DIR}/winpr/include"
    "${CMAKE_BINARY_DIR}/freerdp/include"
    "${CMAKE_BINARY_DIR}/freerdp/winpr/include"
    "${OPENSSL_INCLUDE_DIR}"
)
target_link_libraries(
  jts-freerdp-capability-robustness
  PRIVATE
    freerdp-client
    freerdp
    winpr
    fuzzer_config
)

set_target_properties(
  jts-freerdp-capability-robustness
  PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
