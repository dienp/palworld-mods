cmake_minimum_required(VERSION 3.22)

project(DeepSalvageNativeProof LANGUAGES CXX)

if(NOT DEFINED UE4SS_ROOT)
  message(FATAL_ERROR "Set UE4SS_ROOT to a checked-out RE-UE4SS source tree.")
endif()

add_subdirectory("${UE4SS_ROOT}" "${CMAKE_BINARY_DIR}/RE-UE4SS")

add_library(DeepSalvageNativeProof SHARED
  src/dllmain.cpp
)

target_compile_features(DeepSalvageNativeProof PRIVATE cxx_std_23)
target_link_libraries(DeepSalvageNativeProof PUBLIC UE4SS)

set_target_properties(DeepSalvageNativeProof PROPERTIES
  OUTPUT_NAME main
)
