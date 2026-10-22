//! Small helpers around InkView, PocketBook's SDK

const builtin = @import("builtin");
const std = @import("std");
const pb = @import("c");
const net = @import("net.zig");

const app_title = @import("build_options").app_name;

/// Writes to the log of debug builds, release builds stay silent.
/// Zig's own I/O layer makes system calls the reader's 3.10 kernel lacks, so through libc.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// An error dialog. A failed request says why it failed, other errors give their name.
pub fn showError(text: []const u8, err: anyerror) void {
    var reason_buf: [256]u8 = undefined;
    const reason = if (err == error.RequestFailed) net.lastFailure(&reason_buf) else @errorName(err);

    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "{s}:\n{s}", .{ text, reason }, 0) catch "Error";
    trace("error: {s}\n", .{msg});
    pb.Message(pb.ICON_ERROR, app_title, msg.ptr, 10000);
}

pub fn ensureNetwork() bool {
    if (pb.QueryNetwork() & pb.NET_CONNECTED != 0) return true;
    return pb.NetConnect(null) == pb.NET_OK;
}
