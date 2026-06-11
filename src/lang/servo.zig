//! LewanSoul/Hiwonder serial-bus servo protocol — pure packet builder.
//! No hardware dependencies; compiles and tests on the host.
//!
//! Frame format (§ of the LewanSoul bus-servo manual):
//!   0x55 0x55 | ID | LEN | CMD | PARAMS... | CHK
//!
//! LEN = (number of params) + 3   (covers ID, LEN, CMD, PARAMS, CHK)
//! CHK = ~(ID + LEN + CMD + sum(PARAMS)) & 0xFF
//!
//! Degrees ∈ [0, 240] map to position ∈ [0, 1000].
const std = @import("std");

// ─── Command codes ────────────────────────────────────────────────────────────

pub const CMD_MOVE  : u8 = 0x01; // position + time; time=0 → max speed
pub const CMD_TORQUE: u8 = 0x1E; // load/unload: 0=free, 1=hold

// ─── Conversion ───────────────────────────────────────────────────────────────

/// Convert degrees [0, 240] to raw servo position [0, 1000].
/// Clamps the input so out-of-range degrees don't corrupt the packet.
pub fn degToPos(deg: f32) u16 {
    const clamped = std.math.clamp(deg, 0.0, 240.0);
    return @intFromFloat(clamped / 240.0 * 1000.0);
}

// ─── Checksum ─────────────────────────────────────────────────────────────────

/// Compute LewanSoul checksum over `body` — the packet bytes starting at ID
/// (i.e. everything after the two 0x55 header bytes, excluding the CHK byte
/// itself).  CHK = ~(sum of body bytes) & 0xFF.
pub fn calcChk(body: []const u8) u8 {
    var sum: u8 = 0;
    for (body) |b| sum +%= b;
    return ~sum;
}

// ─── Packet builders ──────────────────────────────────────────────────────────

/// Build a MOVE command packet (10 bytes).
/// Positions the servo to `deg` degrees at maximum speed (time = 0).
pub fn buildMovePacket(id: u8, deg: f32) [10]u8 {
    const pos = degToPos(deg);
    const pos_lo: u8 = @truncate(pos);
    const pos_hi: u8 = @truncate(pos >> 8);
    // ID LEN CMD posLo posHi timeLo timeHi — 7 bytes, so LEN = 4+3 = 7
    const body = [_]u8{ id, 7, CMD_MOVE, pos_lo, pos_hi, 0, 0 };
    return [_]u8{ 0x55, 0x55 } ++ body ++ [_]u8{calcChk(&body)};
}

/// Build a torque (load/unload) packet (7 bytes).
/// `on = true` → hold position; `on = false` → free-wheel.
pub fn buildTorquePacket(id: u8, on: bool) [7]u8 {
    const param: u8 = if (on) 1 else 0;
    // ID LEN CMD param — 4 bytes, so LEN = 1+3 = 4
    const body = [_]u8{ id, 4, CMD_TORQUE, param };
    return [_]u8{ 0x55, 0x55 } ++ body ++ [_]u8{calcChk(&body)};
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "degToPos boundaries" {
    try testing.expectEqual(@as(u16, 0),    degToPos(0.0));
    try testing.expectEqual(@as(u16, 1000), degToPos(240.0));
    // clamping
    try testing.expectEqual(@as(u16, 0),    degToPos(-10.0));
    try testing.expectEqual(@as(u16, 1000), degToPos(300.0));
}

test "degToPos 90 degrees = 375" {
    try testing.expectEqual(@as(u16, 375), degToPos(90.0));
}

test "buildMovePacket golden vector: id=1 deg=90 → 55 55 01 07 01 77 01 00 00 7e" {
    // pos = 375 = 0x0177; posLo=0x77 posHi=0x01; time=0
    // CHK = ~(0x01+0x07+0x01+0x77+0x01+0x00+0x00) & 0xFF = ~0x81 = 0x7E
    const pkt = buildMovePacket(1, 90.0);
    const expected = [10]u8{ 0x55, 0x55, 0x01, 0x07, 0x01, 0x77, 0x01, 0x00, 0x00, 0x7E };
    try testing.expectEqualSlices(u8, &expected, &pkt);
}

test "buildMovePacket checksum round-trip" {
    // Verify that CHK is correct by recomputing over the body bytes.
    const pkt = buildMovePacket(3, 120.0);
    // body = pkt[2..9] (ID through last param)
    const recomputed = calcChk(pkt[2..9]);
    try testing.expectEqual(recomputed, pkt[9]);
}

test "buildTorquePacket on" {
    const pkt = buildTorquePacket(2, true);
    // body: id=2, len=4, cmd=0x1E, param=1
    // CHK = ~(2+4+0x1E+1) & 0xFF = ~0x25 = 0xDA
    try testing.expectEqual(@as(u8, 0x55), pkt[0]);
    try testing.expectEqual(@as(u8, 0x55), pkt[1]);
    try testing.expectEqual(@as(u8, 2),    pkt[2]); // id
    try testing.expectEqual(@as(u8, 4),    pkt[3]); // len
    try testing.expectEqual(CMD_TORQUE,    pkt[4]);
    try testing.expectEqual(@as(u8, 1),    pkt[5]); // on
    // Verify checksum
    const recomputed = calcChk(pkt[2..6]);
    try testing.expectEqual(recomputed, pkt[6]);
}

test "buildTorquePacket off param=0" {
    const pkt = buildTorquePacket(5, false);
    try testing.expectEqual(@as(u8, 0), pkt[5]); // param=0 for off
    const recomputed = calcChk(pkt[2..6]);
    try testing.expectEqual(recomputed, pkt[6]);
}
