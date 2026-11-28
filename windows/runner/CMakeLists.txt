cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/app_branding.cmake")
configure_file("app_branding.h.in" "${CMAKE_CURRENT_BINARY_DIR}/app_branding.h" @ONLY)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "media_controls.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
  "${CMAKE_CURRENT_BINARY_DIR}/app_branding.h"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
# MSVC 14.51+ treats the deprecation of <experimental/coroutine> as a hard error;
# C++/WinRT (used by media_controls.cpp) still includes that header under C++17.
target_compile_definitions(${BINARY_NAME} PRIVATE _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "comctl32.lib" "windowsapp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# PY 沙箱：把 scripts/prepare_windows_python.py 产出的内置 Python 运行时
# 拷到可执行文件旁的 python/ 目录，Dart 侧 ProcessPyBackend 从这里找解释器。
# 备料由 scripts/build_windows.py 在 flutter build 之前完成。这里只警告不中断：
# 本地 `flutter run -d windows` 不必为 py 沙箱先下载几十 MB；正式安装包由
# scripts/package_release.py 校验 python/ 与依赖，缺了就拒绝出包。
set(PY_RUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/python")
if(EXISTS "${PY_RUNTIME_DIR}/python.exe")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${PY_RUNTIME_DIR}/." "$<TARGET_FILE_DIR:${BINARY_NAME}>/python"
    COMMENT "Copying embedded Python runtime")
else()
  message(WARNING
    "未找到内置 CPython：${PY_RUNTIME_DIR}\n"
    "py 沙箱在本机不可用；出正式包前请运行 python scripts/prepare_windows_python.py")
endif()
