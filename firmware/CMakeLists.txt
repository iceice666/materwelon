cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2)
set(PICO_PLATFORM rp2350-arm-s)

if(NOT DEFINED ENV{PICO_SDK_PATH})
    message(FATAL_ERROR "PICO_SDK_PATH environment variable not set")
endif()
set(PICO_SDK_PATH "$ENV{PICO_SDK_PATH}")
include(${PICO_SDK_PATH}/pico_sdk_init.cmake)

project(materwelon C ASM)
set(CMAKE_C_STANDARD 11)

# Disable pico C++ extras — project is C + Zig only
set(PICO_CXX_ENABLE_EXCEPTIONS 0)
set(PICO_CXX_ENABLE_RTTI 0)
pico_sdk_init()

# pico-sdk Platform/PICO.cmake omits CXX rules that CMake 4.x now requires.
if(NOT DEFINED CMAKE_CXX_COMPILE_OBJECT)
    set(CMAKE_INCLUDE_FLAG_CXX           "-I")
    set(CMAKE_INCLUDE_SYSTEM_FLAG_CXX    "-isystem ")
    set(CMAKE_CXX_LINKER_WRAPPER_FLAG    "-Wl,")
    set(CMAKE_CXX_LINKER_WRAPPER_FLAG_SEP ",")
    set(CMAKE_CXX_COMPILE_OBJECT
        "<CMAKE_CXX_COMPILER> <DEFINES> <INCLUDES> <FLAGS> -o <OBJECT> -c <SOURCE>")
    set(CMAKE_CXX_LINK_EXECUTABLE
        "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES>")
endif()

# --- Compile Zig shell logic to an object file ---
find_program(ZIG_EXECUTABLE zig REQUIRED)
set(ZIG_SHELL_OBJ ${CMAKE_CURRENT_BINARY_DIR}/rp2350_shell.o)

# List all Zig sources so CMake reruns the command when any of them change.
set(ZIG_SOURCES
    ${CMAKE_SOURCE_DIR}/../src/platform/rp2350.zig
    ${CMAKE_SOURCE_DIR}/../src/shell/root.zig
    ${CMAKE_SOURCE_DIR}/../src/shell/repl.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/root.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/lexer.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/ast.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/parser.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/value.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/env.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/eval.zig
    ${CMAKE_SOURCE_DIR}/../src/lang/stdlib.zig
)

add_custom_command(
    OUTPUT  ${ZIG_SHELL_OBJ}
    COMMAND ${ZIG_EXECUTABLE} build-obj
            -target thumb-freestanding-eabi
            -mcpu cortex_m33
            -OReleaseSafe
            -fno-stack-check
            ${CMAKE_SOURCE_DIR}/../src/platform/rp2350.zig
            -femit-bin=${ZIG_SHELL_OBJ}
    DEPENDS ${ZIG_SOURCES}
    VERBATIM
)
add_custom_target(zig_shell DEPENDS ${ZIG_SHELL_OBJ})

# --- Main firmware target ---
add_executable(materwelon
    main.c
    ${ZIG_SHELL_OBJ}
)
add_dependencies(materwelon zig_shell)

target_link_libraries(materwelon
    pico_stdlib
)

pico_enable_stdio_uart(materwelon 1)
pico_enable_stdio_usb(materwelon 0)

# Produces materwelon.uf2, materwelon.elf, materwelon.bin, etc.
pico_add_extra_outputs(materwelon)
