//! find-port: locate the Mango brick's serial device by USB VID:PID.
//!
//! Scans /sys/bus/usb/devices for VID=1a86 PID=55d3 (CH340 UART bridge),
//! then searches up to 5 levels deep in that device's sysfs subtree for
//! a ttyUSB* or ttyACM* node.  Prints /dev/<name> on success; exits 1
//! with a message on failure.

const std = @import("std");
const Io  = std.Io;
const Dir = std.Io.Dir;

const usb_devices = "/sys/bus/usb/devices";
const vid_want    = "1a86";
const pid_want    = "55d3";

const stdout_fd: std.posix.fd_t = 1;
const stderr_fd: std.posix.fd_t = 2;

fn writeAll(fd: std.posix.fd_t, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = std.posix.system.write(fd, s[off..].ptr, s.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR    => continue,
            else     => return,
        }
    }
}

fn writeFmt(fd: std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    writeAll(fd, s);
}

pub fn main(init: std.process.Init) void {
    const io = init.io;

    var base = Dir.openDirAbsolute(io, usb_devices, .{ .iterate = true }) catch {
        writeAll(stderr_fd, "error: cannot open " ++ usb_devices ++ "\n");
        std.process.exit(1);
    };
    defer base.close(io);

    var it = base.iterate();
    while (it.next(io) catch null) |ent| {
        var dev = base.openDir(io, ent.name, .{ .iterate = true }) catch continue;
        defer dev.close(io);

        if (!matchSysFile(io, dev, "idVendor", vid_want)) continue;
        if (!matchSysFile(io, dev, "idProduct", pid_want)) continue;

        var name_buf: [64]u8 = undefined;
        if (findTty(io, dev, &name_buf, 0)) |name| {
            writeFmt(stdout_fd, "/dev/{s}\n", .{name});
            return;
        }
    }

    writeAll(stderr_fd,
        "Mango brick not found in firmware mode " ++
        "(connect UART cable or check CH340 driver)\n");
    std.process.exit(1);
}

/// Read a sysfs attribute and compare its trimmed content to `want`.
fn matchSysFile(io: Io, dir: Dir, attr: []const u8, want: []const u8) bool {
    var buf: [32]u8 = undefined;
    const content = dir.readFile(io, attr, &buf) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, content, " \t\r\n"), want);
}

/// Recursively search `dir` for the first ttyUSB* or ttyACM* entry,
/// following symlinks, up to depth 5.  Returns a slice into `buf`.
fn findTty(io: Io, dir: Dir, buf: []u8, depth: u8) ?[]u8 {
    if (depth > 5) return null;
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (std.mem.startsWith(u8, ent.name, "ttyUSB") or
            std.mem.startsWith(u8, ent.name, "ttyACM"))
        {
            const n = @min(ent.name.len, buf.len);
            @memcpy(buf[0..n], ent.name[0..n]);
            return buf[0..n];
        }
        // Attempt to recurse into every entry; sysfs d_type is often DT_UNKNOWN
        // so we can't filter by kind — openDir fails harmlessly on non-dirs.
        var sub = dir.openDir(io, ent.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        if (findTty(io, sub, buf, depth + 1)) |found| return found;
    }
    return null;
}
