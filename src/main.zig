//! Reading Stats: what the reader's library knows about your reading, on the reader.

const std = @import("std");
const pb = @import("c");

const library = @import("library.zig");
const journal = @import("journal.zig");
const stats = @import("stats.zig");
const dates = @import("dates.zig");
const update = @import("update.zig");
const Policy = @import("update_check.zig").Policy;
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;
const showError = pocketbook.showError;

const app_title = @import("build_options").app_name;

/// A line of a list: a title, and a second, grey line under it
const Row = struct {
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    /// What opening it does, if anything
    opens: ?Action = null,
    /// A heading between parts of a list, not a book
    heading: bool = false,
};

const List = enum { reading, finished, unread, activity, library };

/// What opening a row does: open a list, or look for an update
const Action = union(enum) { list: List, update };

/// A list on screen. Opening a row pushes one, Back pops it
const Screen = struct {
    arena: std.heap.ArenaAllocator,
    title: [:0]const u8,
    rows: []const Row,
    pos: c_int = 0,
};

/// InkView callbacks carry no user pointer, so the app state lives here
var gpa: std.mem.Allocator = undefined;
var data_arena: std.heap.ArenaAllocator = undefined;
var screens: std.ArrayList(Screen) = .empty;

var books: []const library.Book = &.{};
var records: []const journal.Record = &.{};
/// The reader's time zone, as an offset to UTC in seconds
var utc_offset: i32 = 0;
var today: dates.Day = 0;

var item_height: c_int = 0;
var padding: c_int = 0;
var title_font: ?*pb.ifont = null;
var detail_font: ?*pb.ifont = null;
var heading_font: ?*pb.ifont = null;

/// The app's settings: "updates=all" (default), "stable" (no nightly builds) or "off"
const config_path = "/mnt/ext1/system/config/reading-stats.cfg";

/// Which updates the start screen offers
var update_policy: Policy = .off;

fn readUpdatePolicy() Policy {
    if (!update.enabled) return .off;
    const config = pb.OpenConfig(config_path, null) orelse return .all;
    defer pb.CloseConfigNoSave(config);
    return Policy.parse(std.mem.span(pb.ReadString(config, "updates", "all")));
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
// time_t is a long in the reader's glibc
extern "c" fn localtime_r(timer: *const c_long, result: *Tm) ?*Tm;
extern "c" fn time(timer: ?*c_long) c_long;

/// Reads the library and the journal, and writes down what changed since last time
fn loadData() !void {
    const allocator = data_arena.allocator();
    const now = time(null);
    var tm: Tm = undefined;
    utc_offset = if (localtime_r(&now, &tm) != null) @intCast(tm.gmtoff) else 0;
    today = dates.dayOf(now, utc_offset);

    books = try library.load(allocator, library.default_path);
    trace("{d} books\n", .{books.len});

    const known = try journal.load(allocator, journal.default_path);
    const new = try journal.changes(allocator, known, books);
    // Without the journal the statistics of today still work, only the history is missing
    journal.append(journal.default_path, new) catch |err| trace("journal not written: {s}\n", .{@errorName(err)});
    records = try std.mem.concat(allocator, journal.Record, &.{ known, new });
    trace("journal: {d} records, {d} new\n", .{ records.len, new.len });
}

fn mainHandler(event_type: c_int, par1: c_int, _: c_int) callconv(.c) c_int {
    switch (event_type) {
        pb.EVT_INIT => {
            _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, app_title, null);

            item_height = @divTrunc(pb.ScreenHeight(), 10);
            padding = @divTrunc(item_height, 8);
            title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 4), 1);
            detail_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(item_height, 5), 1);
            heading_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 5), 1);

            update_policy = readUpdatePolicy();
            loadData() catch |err| {
                showError("Could not read the library", err);
                pb.CloseApp();
                return 0;
            };
            pushScreen(app_title, startRows) catch {
                pb.CloseApp();
                return 0;
            };
        },
        // Also sent when the app comes back to the front
        pb.EVT_SHOW => if (screens.items.len > 0) showList(),
        pb.EVT_KEYPRESS => if (par1 == pb.IV_KEY_BACK) pb.CloseApp(),
        pb.EVT_EXIT => {
            for (screens.items) |*screen| screen.arena.deinit();
            screens.deinit(gpa);
            data_arena.deinit();
            if (title_font) |f| pb.CloseFont(f);
            if (detail_font) |f| pb.CloseFont(f);
            if (heading_font) |f| pb.CloseFont(f);
        },
        else => {},
    }
    return 0;
}

const RowsFn = fn (std.mem.Allocator) anyerror![]const Row;

fn pushScreen(title: [:0]const u8, comptime rows: RowsFn) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const list = try rows(arena.allocator());
    try screens.append(gpa, .{ .arena = arena, .title = title, .rows = list });
}

fn showList() void {
    const screen = &screens.items[screens.items.len - 1];
    pb.OpenList(screen.title.ptr, null, pb.ScreenWidth(), item_height, @intCast(screen.rows.len), screen.pos, listHandler);
}

fn listHandler(action: c_int, x: c_int, y: c_int, idx: c_int, state: c_int) callconv(.c) c_int {
    if (screens.items.len == 0) return 0;
    const screen = &screens.items[screens.items.len - 1];

    switch (action) {
        pb.LIST_PAINT => {
            if (idx < 0 or idx >= screen.rows.len) return 0;
            paintRow(screen.rows[@intCast(idx)], x, y, state != 0);
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= screen.rows.len) return 0;
            screen.pos = idx;
            const row = screen.rows[@intCast(idx)];
            const opens = row.opens orelse return 1;
            const list = switch (opens) {
                .list => |list| list,
                .update => {
                    update.checkForUpdate(update_policy);
                    return 1;
                },
            };
            const opened = switch (list) {
                .reading => pushScreen("Reading", readingRows),
                .finished => pushScreen("Finished", finishedRows),
                .unread => pushScreen("Not started", unreadRows),
                .activity => pushScreen("Activity", activityRows),
                .library => pushScreen("Library", libraryRows),
            };
            opened catch |err| {
                showError("Could not open the list", err);
                return 1;
            };
            showList();
        },
        // Back: to the previous list, or out of the app from the start screen
        pb.LIST_EXIT => {
            _ = pb.SetEventHandler(mainHandler);
            var closed = screens.pop() orelse return 1;
            closed.arena.deinit();
            if (screens.items.len == 0) {
                pb.CloseApp();
                return 1;
            }
            showList();
        },
        else => return 0,
    }
    return 1;
}

fn paintRow(row: Row, x: c_int, y: c_int, selected: bool) void {
    const width = pb.ScreenWidth();
    const text_width = width - 2 * padding;
    const line_height = @divTrunc(item_height - 2 * padding, 2);
    const flags = pb.ALIGN_LEFT | pb.VALIGN_MIDDLE | pb.DOTS;

    if (row.heading) {
        pb.SetFont(heading_font, pb.DGRAY);
        _ = pb.DrawTextRect(x + padding, y + item_height - padding - line_height, text_width, line_height, row.title.ptr, flags);
    } else {
        pb.SetFont(title_font, pb.BLACK);
        _ = pb.DrawTextRect(x + padding, y + padding, text_width, line_height, row.title.ptr, flags);
        pb.SetFont(detail_font, pb.DGRAY);
        _ = pb.DrawTextRect(x + padding, y + padding + line_height, text_width, line_height, row.detail.ptr, flags);
    }
    pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
    if (selected and !row.heading) pb.DrawSelection(x, y, width, item_height, pb.BLACK);
}

fn print(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, args, 0);
}

fn z(allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    return allocator.dupeSentinel(u8, text, 0);
}

fn plural(count: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

/// "41 %"
fn percent(buf: []u8, permille: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d} %", .{permille / 10}) catch "";
}

fn startRows(allocator: std.mem.Allocator) ![]const Row {
    const summary = stats.summarize(books);
    var rows: std.ArrayList(Row) = .empty;

    const reading = try stats.shelf(allocator, books, .reading);
    var ago_buf: [32]u8 = undefined;
    try rows.append(allocator, .{
        .title = "Reading",
        .detail = if (reading.len > 0)
            try print(allocator, "{d} {s} · last: {s}, {s}", .{ reading.len, plural(reading.len, "book", "books"), reading[0].title, lastRead(&ago_buf, reading[0]) })
        else
            "No book being read",
        .opens = .{ .list = .reading },
    });

    const finished = try stats.finishedPerMonth(allocator, books, utc_offset);
    const this_month: usize = if (finished.len > 0 and finished[0].month == dates.monthOf(today)) finished[0].count else 0;
    try rows.append(allocator, .{
        .title = "Finished",
        .detail = try print(allocator, "{d} {s} · {d} this month", .{ summary.finished, plural(summary.finished, "book", "books"), this_month }),
        .opens = .{ .list = .finished },
    });

    try rows.append(allocator, .{
        .title = "Not started",
        .detail = try print(allocator, "{d} {s}", .{ summary.unread, plural(summary.unread, "book", "books") }),
        .opens = .{ .list = .unread },
    });

    const activity = try journal.activity(allocator, records, today, utc_offset);
    try rows.append(allocator, .{
        .title = "Activity",
        .detail = if (activity.days > 0)
            try print(allocator, "{d} reading {s} in the last 30 days · streak: {d}", .{ activity.days_last_30, plural(activity.days_last_30, "day", "days"), activity.streak })
        else
            "Recorded from now on, each time you open this app",
        .opens = .{ .list = .activity },
    });

    const authors = try stats.authors(allocator, books);
    try rows.append(allocator, .{
        .title = "Library",
        .detail = try print(allocator, "{d} {s} · {d} {s}", .{ summary.books, plural(summary.books, "book", "books"), authors.len, plural(authors.len, "author", "authors") }),
        .opens = .{ .list = .library },
    });

    if (update_policy != .off) {
        var buf: [128]u8 = undefined;
        try rows.append(allocator, .{
            .title = "Check for updates",
            .detail = try z(allocator, update.describeInstalled(&buf)),
            .opens = .update,
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn lastRead(buf: []u8, book: library.Book) []const u8 {
    const progress = book.progress orelse return "";
    const last = @max(progress.opened, progress.moved);
    if (last == 0) return "";
    return dates.formatAgo(buf, dates.dayOf(last, utc_offset), today);
}

fn readingRows(allocator: std.mem.Allocator) ![]const Row {
    const list = try stats.shelf(allocator, books, .reading);
    const rows = try allocator.alloc(Row, list.len);
    for (list, rows) |book, *row| {
        const progress = book.progress.?;
        var percent_buf: [8]u8 = undefined;
        var ago_buf: [32]u8 = undefined;
        const pages = if (progress.pages > 0)
            try print(allocator, " · page {d} of {d}", .{ progress.page, progress.pages })
        else
            "";
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = try print(allocator, "{s} · read {s}{s}", .{ percent(&percent_buf, progress.permille()), lastRead(&ago_buf, book), pages }),
        };
    }
    return rows;
}

fn finishedRows(allocator: std.mem.Allocator) ![]const Row {
    const list = try stats.shelf(allocator, books, .finished);
    const rows = try allocator.alloc(Row, list.len);
    for (list, rows) |book, *row| {
        const progress = book.progress.?;
        var day_buf: [24]u8 = undefined;
        const when = if (progress.completed_at > 0) dates.formatDay(&day_buf, dates.dayOf(progress.completed_at, utc_offset), today) else "date unknown";
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = try print(allocator, "Finished {s} · {s}", .{ when, book.author }),
        };
    }
    return rows;
}

fn unreadRows(allocator: std.mem.Allocator) ![]const Row {
    const list = try stats.shelf(allocator, books, .unread);
    const rows = try allocator.alloc(Row, list.len);
    for (list, rows) |book, *row| {
        var day_buf: [24]u8 = undefined;
        const added = if (book.added > 0) dates.formatDay(&day_buf, dates.dayOf(book.added, utc_offset), today) else "?";
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = try print(allocator, "{s} · added {s}{s}", .{ book.author, added, if (book.on_device) "" else " · in the cloud" }),
        };
    }
    return rows;
}

fn activityRows(allocator: std.mem.Allocator) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const activity = try journal.activity(allocator, records, today, utc_offset);
    var day_buf: [24]u8 = undefined;

    try rows.append(allocator, .{
        .title = try print(allocator, "{d} reading {s} in the last 30 days", .{ activity.days_last_30, plural(activity.days_last_30, "day", "days") }),
        .detail = try print(allocator, "Current streak: {d} {s}", .{ activity.streak, plural(activity.streak, "day", "days") }),
    });
    try rows.append(allocator, .{
        .title = "How this works",
        .detail = if (activity.since) |since|
            try print(allocator, "Progress noted each time this app opens, since {s}", .{dates.formatDay(&day_buf, since, today)})
        else
            "Progress is noted each time this app opens",
    });

    const list = try journal.steps(allocator, records);
    if (list.len > 0) try rows.append(allocator, .{ .title = "Recent progress", .heading = true });
    for (list) |step| {
        var from_buf: [8]u8 = undefined;
        var to_buf: [8]u8 = undefined;
        const day = dates.formatDay(&day_buf, dates.dayOf(step.record.time, utc_offset), today);
        const to = percent(&to_buf, step.record.permille);
        try rows.append(allocator, .{
            .title = try z(allocator, step.record.title),
            .detail = if (step.record.permille == 1000)
                try print(allocator, "{s} · finished", .{day})
            else if (step.from) |from|
                try print(allocator, "{s} · {s} → {s}", .{ day, percent(&from_buf, from), to })
            else
                try print(allocator, "{s} · at {s}", .{ day, to }),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn libraryRows(allocator: std.mem.Allocator) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const summary = stats.summarize(books);
    var month_buf: [16]u8 = undefined;

    try rows.append(allocator, .{
        .title = try print(allocator, "{d} {s}", .{ summary.books, plural(summary.books, "book", "books") }),
        .detail = try print(allocator, "{d} on the reader, {d} only in the cloud", .{ summary.on_device, summary.books - summary.on_device }),
    });

    const finished = try stats.finishedPerMonth(allocator, books, utc_offset);
    if (finished.len > 0) try rows.append(allocator, .{ .title = "Finished per month", .heading = true });
    for (finished) |entry| try rows.append(allocator, .{
        .title = try z(allocator, dates.formatMonth(&month_buf, entry.month)),
        .detail = try print(allocator, "{d} {s} finished", .{ entry.count, plural(entry.count, "book", "books") }),
    });

    const authors = try stats.authors(allocator, books);
    if (authors.len > 0) try rows.append(allocator, .{ .title = "Authors", .heading = true });
    for (authors[0..@min(authors.len, 20)]) |entry| try rows.append(allocator, .{
        .title = try z(allocator, entry.name),
        .detail = try print(allocator, "{d} {s}", .{ entry.count, plural(entry.count, "book", "books") }),
    });

    const series = try stats.series(allocator, books);
    if (series.len > 0) try rows.append(allocator, .{ .title = "Series", .heading = true });
    for (series) |entry| try rows.append(allocator, .{
        .title = try z(allocator, entry.name),
        .detail = try print(allocator, "{d} {s}", .{ entry.count, plural(entry.count, "book", "books") }),
    });

    const added = try stats.addedPerMonth(allocator, books, utc_offset);
    if (added.len > 0) try rows.append(allocator, .{ .title = "Added per month", .heading = true });
    for (added) |entry| try rows.append(allocator, .{
        .title = try z(allocator, dates.formatMonth(&month_buf, entry.month)),
        .detail = try print(allocator, "{d} {s} added", .{ entry.count, plural(entry.count, "book", "books") }),
    });

    const formats = try stats.formats(allocator, books);
    if (formats.len > 0) try rows.append(allocator, .{ .title = "Formats", .heading = true });
    for (formats) |entry| {
        var upper: [16]u8 = undefined;
        const name = entry.name[0..@min(entry.name.len, upper.len)];
        try rows.append(allocator, .{
            .title = try z(allocator, std.ascii.upperString(upper[0..name.len], name)),
            .detail = try print(allocator, "{d} {s}", .{ entry.count, plural(entry.count, "book", "books") }),
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn main() void {
    gpa = std.heap.c_allocator;
    data_arena = .init(gpa);
    pb.InkViewMain(mainHandler);
}
