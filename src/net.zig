//! Downloads through the reader's libcurl. Reading Stats only needs them to update itself.

const builtin = @import("builtin");
const std = @import("std");
const curl = @import("libcurl.zig");
const Failure = @import("failure.zig").Failure;

const user_agent = "pb-stats/" ++ @import("build_options").version;

/// Why the last request failed, see `lastFailure`
var failure: Failure = .{};
var failure_text: [curl.CURL_ERROR_SIZE]u8 = undefined;

/// Describes why the last request ended in error.RequestFailed
pub fn lastFailure(buf: []u8) []const u8 {
    return failure.describe(buf);
}

const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
};

/// Where a response goes: kept in memory, or written into a file
const Target = union(enum) {
    memory: *Buffer,
    file: *std.c.FILE,
};

fn curlWriteBuffer(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const buffer: *Buffer = @ptrCast(@alignCast(userdata));
    const len = size * nmemb;
    // Returning less than len makes curl abort the transfer
    buffer.bytes.appendSlice(buffer.allocator, ptr[0..len]) catch return 0;
    return len;
}

fn perform(url: [:0]const u8, target: Target) !void {
    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, user_agent);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 120));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    // Treat HTTP 4xx/5xx as an error instead of handing the error page to the caller
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FAILONERROR, @as(c_long, 1));

    switch (target) {
        .memory => |buffer| {
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, &curlWriteBuffer);
            _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, buffer);
        },
        // Without a write function curl writes to the C file itself
        .file => |file| _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, file),
    }

    if (builtin.mode == .debug) {
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_VERBOSE, @as(c_long, 1));
    }

    var error_buf = std.mem.zeroes([curl.CURL_ERROR_SIZE]u8);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_ERRORBUFFER, &error_buf);

    const code = curl.curl_easy_perform(handle);
    if (code != curl.CURLE_OK) {
        var status: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, curl.CURLINFO_RESPONSE_CODE, &status);
        // The buffer goes away with this function, keep its text
        const text = std.mem.sliceTo(&error_buf, 0);
        @memcpy(failure_text[0..text.len], text);
        failure = .{ .http_status = status, .curl_text = failure_text[0..text.len], .curl_code = code };
        return error.RequestFailed;
    }
}

/// Loads what is at `url` into memory
pub fn fetch(allocator: std.mem.Allocator, url: [:0]const u8) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    errdefer buffer.bytes.deinit(allocator);
    try perform(url, .{ .memory = &buffer });
    return buffer.bytes.toOwnedSlice(allocator);
}

/// Saves what is at `url` as `filename` in `target_dir`. Nothing is left behind on failure.
pub fn download(url: [:0]const u8, target_dir: []const u8, filename: []const u8) !void {
    var path_buf: [384]u8 = undefined;
    const target_path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ target_dir, filename }, 0);

    const fh = std.c.fopen(target_path.ptr, "wb") orelse return error.CannotOpenFileForWriting;
    perform(url, .{ .file = fh }) catch |err| {
        _ = std.c.fclose(fh);
        _ = std.c.unlink(target_path.ptr);
        return err;
    };
    if (std.c.fclose(fh) != 0) {
        _ = std.c.unlink(target_path.ptr);
        return error.CannotWriteFile;
    }
}
