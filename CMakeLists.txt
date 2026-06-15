cmake_minimum_required(VERSION 3.19 FATAL_ERROR)

project(Piccolo VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF)

set(PICCOLO_TARGET_ARM64 OFF)
if(CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "ARM64"
   OR CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  set(PICCOLO_TARGET_ARM64 ON)
endif()

if(PICCOLO_TARGET_ARM64
   AND (NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
        OR NOT CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC"))
  message(FATAL_ERROR
    "Piccolo ARM64 requires clang-cl. The bundled Jolt version uses Clang "
    "builtins such as __builtin_shufflevector in its ARM64 implementation, "
    "which MSVC cannot compile.\n"
    "CMake GUI: delete the existing cache, then either launch "
    "'cmake-gui --preset=vs2026-arm64', or select generator "
    "'Visual Studio 18 2026', platform 'ARM64', and toolset 'ClangCL'.")
endif()

message(STATUS
  "Piccolo target architecture: ${CMAKE_CXX_COMPILER_ARCHITECTURE_ID}; "
  "compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")

include(CMakeDependentOption)

# ---- Include guards ----
if(PROJECT_SOURCE_DIR STREQUAL PROJECT_BINARY_DIR)
  message(
    FATAL_ERROR
      "In-source builds not allowed. Please make a new directory (called a build directory) and run CMake from there."
  )
endif()

set(PICCOLO_ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(CMAKE_INSTALL_PREFIX "${PICCOLO_ROOT_DIR}/bin")
set(BINARY_ROOT_DIR "${CMAKE_INSTALL_PREFIX}/")


add_subdirectory(engine)
