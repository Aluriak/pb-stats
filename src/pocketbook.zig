//! Small helpers around InkView, PocketBook's SDK

const builtin = @import("builtin");
const std = @import("std");
const pb = @import("c");

const app_title = @import("build_options").app_name;

/// Writes to the log of debug builds, release builds stay silent.
/// Zig's own I/O layer makes system calls the reader's 3.10 kernel lacks, so through libc.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .debug) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// An error dialog, with the name of the error
pub fn showError(text: []const u8, err: anyerror) void {
    const reason = @errorName(err);

    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "{s}:\n{s}", .{ text, reason }, 0) catch "Error";
    trace("error: {s}\n", .{msg});
    pb.Message(pb.ICON_ERROR, app_title, msg.ptr, 10000);
}
