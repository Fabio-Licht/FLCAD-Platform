cmake_minimum_required(VERSION 3.18)
project(flcad_opencascade LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(FLCAD_OCCT_ROOT "" CACHE PATH "OpenCascade SDK root (contains inc, lib and bin)")
if(NOT FLCAD_OCCT_ROOT AND DEFINED ENV{FLCAD_OCCT_ROOT})
  file(TO_CMAKE_PATH "$ENV{FLCAD_OCCT_ROOT}" FLCAD_OCCT_ROOT)
endif()
if(NOT FLCAD_OCCT_ROOT AND DEFINED ENV{OCCT_ROOT})
  file(TO_CMAKE_PATH "$ENV{OCCT_ROOT}" FLCAD_OCCT_ROOT)
endif()
if(NOT FLCAD_OCCT_ROOT)
  set(_occt_search_roots ${CMAKE_PREFIX_PATH})
  if(WIN32)
    list(APPEND _occt_search_roots
      "$ENV{ProgramFiles}/OpenCASCADE"
      "$ENV{ProgramFiles}/OCCT"
      "C:/FLCAD/SDKs/OCCT")
  endif()
  foreach(_search_root IN LISTS _occt_search_roots)
    if(IS_DIRECTORY "${_search_root}")
      file(GLOB_RECURSE _occt_configs LIST_DIRECTORIES FALSE
        "${_search_root}/OpenCASCADEConfig.cmake")
      list(LENGTH _occt_configs _occt_config_count)
      if(_occt_config_count GREATER 0)
        list(GET _occt_configs 0 _detected_config)
        get_filename_component(_detected_cmake_dir "${_detected_config}" DIRECTORY)
        get_filename_component(FLCAD_OCCT_ROOT "${_detected_cmake_dir}" DIRECTORY)
        set(FLCAD_OCCT_ROOT "${FLCAD_OCCT_ROOT}" CACHE PATH
          "Auto-detected OpenCascade SDK root" FORCE)
        message(STATUS "Auto-detected OpenCascade SDK: ${FLCAD_OCCT_ROOT}")
        break()
      endif()
    endif()
  endforeach()
endif()
if(FLCAD_OCCT_ROOT)
  if(NOT IS_DIRECTORY "${FLCAD_OCCT_ROOT}/inc")
    message(FATAL_ERROR "Invalid OpenCascade SDK: ${FLCAD_OCCT_ROOT}/inc is missing")
  endif()
  list(PREPEND CMAKE_PREFIX_PATH "${FLCAD_OCCT_ROOT}")
  find_path(_occt_cmake_dir OpenCASCADEConfig.cmake
    PATHS
      "${FLCAD_OCCT_ROOT}/cmake"
      "${FLCAD_OCCT_ROOT}/lib/cmake/opencascade"
      "${FLCAD_OCCT_ROOT}/lib/cmake/OpenCASCADE"
    NO_DEFAULT_PATH)
  if(NOT _occt_cmake_dir)
    message(FATAL_ERROR "Invalid OpenCascade SDK: OpenCASCADEConfig.cmake was not found under ${FLCAD_OCCT_ROOT}")
  endif()
  set(OpenCASCADE_DIR "${_occt_cmake_dir}" CACHE PATH "OpenCascade CMake package" FORCE)
endif()
find_package(OpenCASCADE CONFIG REQUIRED COMPONENTS
  FoundationClasses ModelingData ModelingAlgorithms)
foreach(_occt_dir OpenCASCADE_INCLUDE_DIR OpenCASCADE_LIBRARY_DIR OpenCASCADE_BINARY_DIR)
  if(NOT IS_DIRECTORY "${${_occt_dir}}")
    message(FATAL_ERROR "Invalid OpenCascade SDK: ${_occt_dir}=${${_occt_dir}} is missing")
  endif()
endforeach()
add_library(flcad_opencascade SHARED src/flcad_occ_api.cpp)
target_include_directories(flcad_opencascade PUBLIC include ${OpenCASCADE_INCLUDE_DIR} ${OpenCASCADE_INCLUDE_DIRS})
target_link_directories(flcad_opencascade PRIVATE ${OpenCASCADE_LIBRARY_DIR})
set(_flcad_occt_exchange_libraries TKDE TKXSBase TKDESTEP TKDEIGES TKDESTL)
foreach(_library IN LISTS _flcad_occt_exchange_libraries)
  find_library(_path_${_library} NAMES ${_library}
    PATHS "${OpenCASCADE_LIBRARY_DIR}" NO_DEFAULT_PATH REQUIRED)
endforeach()
target_link_libraries(flcad_opencascade PRIVATE
  ${OpenCASCADE_LIBRARIES}
  ${_path_TKDE} ${_path_TKXSBase} ${_path_TKDESTEP} ${_path_TKDEIGES}
  ${_path_TKDESTL})
target_compile_definitions(flcad_opencascade PRIVATE FLCAD_OCC_BUILD)
if(WIN32)
  file(GLOB _occt_runtime_dlls CONFIGURE_DEPENDS "${OpenCASCADE_BINARY_DIR}/*.dll")
  if(NOT _occt_runtime_dlls)
    message(FATAL_ERROR "Invalid OpenCascade SDK: ${OpenCASCADE_BINARY_DIR} contains no runtime DLLs")
  endif()
  get_filename_component(_occt_bundle_root "${FLCAD_OCCT_ROOT}" DIRECTORY)
  file(GLOB_RECURSE _occt_third_party_candidates CONFIGURE_DEPENDS
    "${_occt_bundle_root}/3rdparty*/*.dll")
  foreach(_candidate IN LISTS _occt_third_party_candidates)
    get_filename_component(_candidate_name "${_candidate}" NAME)
    if(_candidate_name MATCHES "^(tbb12|jemalloc|avcodec-57|avformat-57|avutil-55|swscale-4|FreeImage|freetype|openvr_api)\\.dll$" AND
       NOT _candidate MATCHES "[/\\\\]debug[/\\\\]")
      list(APPEND _occt_runtime_dlls "${_candidate}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES _occt_runtime_dlls)
  set(FLCAD_OCCT_RUNTIME_DLLS "${_occt_runtime_dlls}" CACHE INTERNAL
    "OpenCascade runtime DLLs including required third-party libraries")
  add_custom_command(TARGET flcad_opencascade POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      ${_occt_runtime_dlls} $<TARGET_FILE_DIR:flcad_opencascade>
    COMMAND_EXPAND_LISTS)
endif()
include(CTest)
if(BUILD_TESTING)
  add_executable(flcad_occ_native_smoke tests/native_smoke.cpp)
  target_link_libraries(flcad_occ_native_smoke PRIVATE flcad_opencascade)
  target_include_directories(flcad_occ_native_smoke PRIVATE include)
  add_test(NAME flcad_occ_native_smoke COMMAND flcad_occ_native_smoke)
  # Compile the implementation into a separate executable. Test hooks never
  # enter the production DLL and require no extra exported ABI.
  add_executable(flcad_occ_atomic_output_test tests/atomic_output_test.cpp)
  target_compile_definitions(flcad_occ_atomic_output_test PRIVATE FLCAD_OCC_TESTING)
  target_include_directories(flcad_occ_atomic_output_test PRIVATE include ${OpenCASCADE_INCLUDE_DIR} ${OpenCASCADE_INCLUDE_DIRS})
  target_link_directories(flcad_occ_atomic_output_test PRIVATE ${OpenCASCADE_LIBRARY_DIR})
  target_link_libraries(flcad_occ_atomic_output_test PRIVATE
    ${OpenCASCADE_LIBRARIES}
    ${_path_TKDE} ${_path_TKXSBase} ${_path_TKDESTEP} ${_path_TKDEIGES}
    ${_path_TKDESTL})
  if(WIN32)
    add_custom_command(TARGET flcad_occ_atomic_output_test POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${_occt_runtime_dlls} $<TARGET_FILE_DIR:flcad_occ_atomic_output_test>
      COMMAND_EXPAND_LISTS)
  endif()
  add_test(NAME flcad_occ_atomic_output_test COMMAND flcad_occ_atomic_output_test)
endif()

if(BUILD_TESTING)
  add_executable(flcad_occ_mesh_stream_test tests/mesh_stream_test.cpp)
  target_compile_definitions(flcad_occ_mesh_stream_test PRIVATE FLCAD_OCC_TESTING)
  target_include_directories(flcad_occ_mesh_stream_test PRIVATE include ${OpenCASCADE_INCLUDE_DIR})
  target_link_directories(flcad_occ_mesh_stream_test PRIVATE ${OpenCASCADE_LIBRARY_DIR})
  target_link_libraries(flcad_occ_mesh_stream_test PRIVATE ${OpenCASCADE_LIBRARIES}
    ${_path_TKDE} ${_path_TKXSBase} ${_path_TKDESTEP} ${_path_TKDEIGES} ${_path_TKDESTL})
  add_test(NAME flcad_occ_mesh_stream_test COMMAND flcad_occ_mesh_stream_test)
endif()

if(BUILD_TESTING)
  add_executable(flcad_occ_mesh_stream_smoke tests/mesh_stream_smoke.cpp)
  target_link_libraries(flcad_occ_mesh_stream_smoke PRIVATE flcad_opencascade)
  add_test(NAME flcad_occ_mesh_stream_smoke COMMAND flcad_occ_mesh_stream_smoke)
endif()
option(FLCAD_OCC_ADDRESS_SANITIZER "Enable MSVC address sanitizer for native validation" OFF)
if(FLCAD_OCC_ADDRESS_SANITIZER AND MSVC)
  foreach(t flcad_opencascade flcad_occ_mesh_stream_test flcad_occ_mesh_stream_smoke)
    if(TARGET ${t})
      target_compile_options(${t} PRIVATE /fsanitize=address /Zi)
      target_link_options(${t} PRIVATE /INCREMENTAL:NO /DEBUG)
    endif()
  endforeach()
endif()

if(BUILD_TESTING)
  enable_language(C)
  add_executable(flcad_occ_mesh_stream_c_abi tests/mesh_stream_c_abi.c)
  target_link_libraries(flcad_occ_mesh_stream_c_abi PRIVATE flcad_opencascade)
  add_test(NAME flcad_occ_mesh_stream_c_abi COMMAND flcad_occ_mesh_stream_c_abi)
endif()
