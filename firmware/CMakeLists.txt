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

# Glob all Zig sources so CMake reruns the command when any of them change.
# (DEPENDS rebuild-tracking only — a stale list would silently produce stale
# firmware, so glob instead of hand-maintaining the file list.)
file(GLOB_RECURSE ZIG_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/../src/*.zig)

add_custom_command(
    OUTPUT  ${ZIG_SHELL_OBJ}
    COMMAND ${ZIG_EXECUTABLE} build-obj
            -target thumb-freestanding-eabi
            -mcpu cortex_m33
            -OReleaseSafe
            -fno-stack-check
            # Root module (rp2350.zig) uses @import("lang") and @import("shell").
            --dep lang
            --dep shell
            -Mroot=${CMAKE_SOURCE_DIR}/../src/platform/rp2350.zig
            # Shell module: repl.zig uses @import("lang").
            --dep lang
            -Mshell=${CMAKE_SOURCE_DIR}/../src/shell/root.zig
            # Lang module: no named-module deps.
            -Mlang=${CMAKE_SOURCE_DIR}/../src/lang/root.zig
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
    hardware_gpio
    hardware_adc
    hardware_uart
)

# ── micro-ROS (Phase B) ────────────────────────────────────────────────────────
# Enable with: cmake -DENABLE_MICROROS=ON ..
# Requires a cortex-m33 rebuild of libmicroros — see firmware/libmicroros/README.
option(ENABLE_MICROROS "Build with micro-ROS /servo_trajectory subscriber" OFF)

if(ENABLE_MICROROS)
    # libmicroros must be rebuilt for cortex-m33 from
    # https://github.com/micro-ROS/micro_ros_raspberrypi_pico_sdk
    # and placed in firmware/libmicroros/{libmicroros.a,include/,pico_uart_transport.h}
    set(MICROROS_DIR ${CMAKE_CURRENT_LIST_DIR}/libmicroros)

    target_sources(materwelon PRIVATE
        uros.c
        ${MICROROS_DIR}/pico_uart_transport.c
    )
    target_include_directories(materwelon PRIVATE ${MICROROS_DIR}/include)
    target_link_directories(materwelon PRIVATE ${MICROROS_DIR})
    target_link_libraries(materwelon microros)
    target_compile_definitions(materwelon PRIVATE ENABLE_MICROROS=1)

    # micro-ROS agent connects over USB CDC; REPL console stays on UART0.
    pico_enable_stdio_usb(materwelon 1)
else()
    pico_enable_stdio_usb(materwelon 0)
endif()

pico_enable_stdio_uart(materwelon 1)

# Produces materwelon.uf2, materwelon.elf, materwelon.bin, etc.
pico_add_extra_outputs(materwelon)
