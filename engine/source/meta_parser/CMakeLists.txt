#cmake_policy(SET CMP0074 OLD)
set(TARGET_NAME PiccoloParser)

#set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/../CMake")

set_property(GLOBAL PROPERTY USE_FOLDERS ON)

file(GLOB_RECURSE HEADERS "*.h")
file(GLOB_RECURSE SOURCES "*.cpp")

source_group(TREE "${CMAKE_CURRENT_SOURCE_DIR}" FILES ${HEADERS} ${SOURCES})


set(LLVM_INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/include ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/mustache ${CMAKE_CURRENT_SOURCE_DIR})
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE ${ENGINE_ROOT_DIR}/bin)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG ${ENGINE_ROOT_DIR}/bin)
# add LLVM includes
include_directories(${LLVM_INCLUDE_DIRS} ${CMAKE_CURRENT_SOURCE_DIR}/parser)

# header files are superflous, but some IDEs (Visual Studio) don't include
# them in the solution explorer without them being added to the list of sources
add_executable(${TARGET_NAME} ${HEADERS} ${SOURCES})

#set_target_properties(meta_parser PROPERTIES FOLDER "generator" ) 

set_target_properties(${TARGET_NAME} PROPERTIES CXX_STANDARD 17)
set_target_properties(${TARGET_NAME} PROPERTIES FOLDER "Tools")

if (CMAKE_HOST_WIN32)
    if(PICCOLO_TARGET_ARM64)
        set(PICCOLO_ARM64_LIBCLANG_DIR "" CACHE PATH
            "Visual Studio LLVM ARM64 root containing bin/libclang.dll and lib/libclang.lib")

        set(_piccolo_arm64_libclang_candidates)
        if(PICCOLO_ARM64_LIBCLANG_DIR)
            list(APPEND _piccolo_arm64_libclang_candidates "${PICCOLO_ARM64_LIBCLANG_DIR}")
        endif()
        if(CMAKE_GENERATOR_INSTANCE)
            list(APPEND _piccolo_arm64_libclang_candidates
                "${CMAKE_GENERATOR_INSTANCE}/VC/Tools/Llvm/ARM64")
        endif()
        if(DEFINED ENV{VCINSTALLDIR})
            list(APPEND _piccolo_arm64_libclang_candidates
                "$ENV{VCINSTALLDIR}/Tools/Llvm/ARM64")
        endif()

        set(_piccolo_arm64_libclang_root "")
        foreach(_candidate IN LISTS _piccolo_arm64_libclang_candidates)
            get_filename_component(_candidate_absolute "${_candidate}" ABSOLUTE)
            if(EXISTS "${_candidate_absolute}/lib/libclang.lib"
               AND EXISTS "${_candidate_absolute}/bin/libclang.dll")
                set(_piccolo_arm64_libclang_root "${_candidate_absolute}")
                break()
            endif()
        endforeach()

        if(NOT _piccolo_arm64_libclang_root)
            message(FATAL_ERROR
                "ARM64 libclang was not found. Install the Visual Studio LLVM ARM64 "
                "component or set PICCOLO_ARM64_LIBCLANG_DIR to its ARM64 directory.")
        endif()

        set(LLVM_LIBRARY_DIR "${_piccolo_arm64_libclang_root}/lib")
        set(LLVM_SHARED_LIBRARY_DIR "${_piccolo_arm64_libclang_root}/bin")
        set(PICCOLO_LIBCLANG_DLL "${LLVM_SHARED_LIBRARY_DIR}/libclang.dll")
        message(STATUS "Piccolo ARM64 libclang: ${PICCOLO_LIBCLANG_DLL}")
    else()
        set(LLVM_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/lib/x64)
        set(LLVM_SHARED_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/bin/x64)
    endif()
    set(CMAKE_CXX_FLAGS_DEBUG "$ENV{CXXFLAGS} /O2 /Ob2")
    target_link_libraries(${TARGET_NAME}  ${LLVM_LIBRARY_DIR}/libclang.lib)
elseif(${CMAKE_HOST_SYSTEM_NAME} STREQUAL "Linux")
    set(LLVM_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/lib/Linux)
    set(LLVM_SHARED_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/bin/Linux)
    set(CMAKE_CXX_FLAGS_DEBUG "$ENV{CXXFLAGS} -O3")
    target_link_libraries(${TARGET_NAME}  ${LLVM_SHARED_LIBRARY_DIR}/libclang.so.12)
elseif(${CMAKE_HOST_SYSTEM_PROCESSOR} STREQUAL "arm64") 
    # link to XCode Toolchains' universal binary libclang.dylib 
    set(LLVM_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/lib/macOS)
    set(LLVM_SHARED_LIBRARY_DIR  ${OSX_DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/lib)
    set(CMAKE_CXX_FLAGS_DEBUG "$ENV{CXXFLAGS} -O3")
    target_link_libraries(${TARGET_NAME}  ${LLVM_SHARED_LIBRARY_DIR}/libclang.dylib)    
else()
    set(LLVM_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/lib/macOS)
    set(LLVM_SHARED_LIBRARY_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/3rd_party/LLVM/bin/macOS)
    set(CMAKE_CXX_FLAGS_DEBUG "$ENV{CXXFLAGS} -O3")
    target_link_libraries(${TARGET_NAME}  ${LLVM_SHARED_LIBRARY_DIR}/libclang.dylib)
endif()

#link_directories(${LLVM_LIBRARY_DIR})

# statically link with Boost & LibClang

add_definitions(-DTIXML_USE_STL)

# copy resources on post build
if(CMAKE_HOST_WIN32 AND PICCOLO_TARGET_ARM64)
    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${PICCOLO_LIBCLANG_DLL}"
            "$<TARGET_FILE_DIR:${TARGET_NAME}>/libclang.dll"
    )
else()
    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        # mustache templates directory
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${LLVM_SHARED_LIBRARY_DIR}"
            $<TARGET_FILE_DIR:${TARGET_NAME}>
    )
endif()

