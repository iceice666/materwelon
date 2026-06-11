const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- lang module: pure language library, no platform deps, host-testable ---
    const lang_mod = b.createModule(.{
        .root_source_file = b.path("src/lang/root.zig"),
        .target = target,
    });

    // --- shell module: REPL layer, platform-agnostic ---
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/shell/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "lang", .module = lang_mod },
        },
    });
    // --- Host REPL executable: `zig build run` ---
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lang", .module = lang_mod },
            .{ .name = "shell", .module = shell_mod },
        },
    });
    const host_exe = b.addExecutable(.{ .name = "materwelon", .root_module = host_mod });
    b.installArtifact(host_exe);
    const run_step = b.step("run", "Run the REPL on the host");
    run_step.dependOn(&b.addRunArtifact(host_exe).step);

    // --- Tests (run on host) ---
    const lang_tests  = b.addTest(.{ .root_module = lang_mod });
    const shell_tests = b.addTest(.{ .root_module = shell_mod });
    const test_step = b.step("test", "Run lang + shell tests on host");
    test_step.dependOn(&b.addRunArtifact(lang_tests).step);
    test_step.dependOn(&b.addRunArtifact(shell_tests).step);

    // --- Check (compile-only, no run) ---
    const check_lang  = b.addTest(.{ .root_module = lang_mod });
    const check_shell = b.addObject(.{ .name = "check_shell", .root_module = shell_mod });
    const check_step  = b.step("check", "Type-check all modules without running");
    check_step.dependOn(&check_lang.step);
    check_step.dependOn(&check_shell.step);
    check_step.dependOn(&host_exe.step);

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
