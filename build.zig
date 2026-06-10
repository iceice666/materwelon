const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // --- lang module: pure language library, no platform deps, host-testable ---
    const lang_mod = b.createModule(.{
        .root_source_file = b.path("src/lang/root.zig"),
        .target = target,
    });

    // --- shell module: REPL layer, platform-agnostic ---
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/shell/root.zig"),
        .target = target,
    });
    _ = shell_mod; // consumed by firmware via CMake/zig build-obj, not zig build

    // --- Tests (run on host) ---
    const lang_tests = b.addTest(.{ .root_module = lang_mod });
    b.step("test", "Run lang tests on host").dependOn(&b.addRunArtifact(lang_tests).step);

    // --- RP2350 firmware (CMake + pico-sdk) ---
    const cmake_configure = b.addSystemCommand(&.{
        "cmake", "-S", "firmware", "-B", "firmware/build", "-DCMAKE_BUILD_TYPE=Release",
    });
    const cmake_build = b.addSystemCommand(&.{
        "cmake", "--build", "firmware/build", "--parallel",
    });
    cmake_build.step.dependOn(&cmake_configure.step);
    b.step("firmware", "Build RP2350 UF2 firmware").dependOn(&cmake_build.step);

    // --- Flash: copy UF2 to mounted RP2350 BOOTSEL drive ---
    const flash = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\UF2=firmware/build/materwelon.uf2
        \\MOUNT=$(findmnt -rno TARGET LABEL=RP2350 2>/dev/null || true)
        \\if [ -z "$MOUNT" ]; then
        \\  echo "RP2350 not in BOOTSEL mode. Put it in BOOTSEL mode first."
        \\  exit 1
        \\fi
        \\echo "Flashing $UF2 -> $MOUNT"
        \\cp "$UF2" "$MOUNT/"
        \\echo "Done."
    });
    flash.step.dependOn(&cmake_build.step);
    b.step("flash", "Build and flash firmware to mango brick").dependOn(&flash.step);
}
