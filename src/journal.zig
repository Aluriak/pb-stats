//! The reading journal: the library only knows where each book is now, so the app writes
//! down every change of progress it sees, each time it starts. Over time this gives the
//! days books were read and how far they went.
//!
//! One line per change, tab separated: "<unix time>\t<book id>\t<permille>\t<title>".
//! The time is when the reading position last moved, as the library recorded it.

const std = @import("std");
const library = @import("library.zig");
const dates = @import("dates.zig");

pub const default_path = "/mnt/ext1/system/config/reading-stats-journal.tsv";

pub const Record = struct {
    time: i64,
    book: i64,
    /// Read so far, in thousandths
    permille: u16,
    title: []const u8,
};

/// Reads the lines of a journal. Lines that cannot be read are skipped.
/// The titles point into `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Record {
    var records: std.ArrayList(Record) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), '\t');
        const time = std.fmt.parseInt(i64, fields.next() orelse continue, 10) catch continue;
        const book = std.fmt.parseInt(i64, fields.next() orelse continue, 10) catch continue;
        const permille = std.fmt.parseInt(u16, fields.next() orelse continue, 10) catch continue;
        try records.append(allocator, .{ .time = time, .book = book, .permille = @min(permille, 1000), .title = fields.rest() });
    }
    return records.toOwnedSlice(allocator);
}

pub fn format(record: Record, buf: []u8) ![]const u8 {
    // Titles never hold tabs or line breaks in the file
    var title_buf: [256]u8 = undefined;
    const title = title_buf[0..@min(record.title.len, title_buf.len)];
    for (title, record.title[0..title.len]) |*out, char| out.* = if (char == '\t' or char == '\n' or char == '\r') ' ' else char;
    return std.fmt.bufPrint(buf, "{d}\t{d}\t{d}\t{s}\n", .{ record.time, record.book, record.permille, title });
}

/// The progress of `books` that the journal does not have yet. A book appears the first time
/// it is seen opened, and again whenever its progress changed since its last record.
pub fn changes(allocator: std.mem.Allocator, records: []const Record, books: []const library.Book) ![]Record {
    var last: std.AutoHashMapUnmanaged(i64, Record) = .empty;
    defer last.deinit(allocator);
    for (records) |record| try last.put(allocator, record.book, record);

    var new: std.ArrayList(Record) = .empty;
    for (books) |book| {
        const progress = book.progress orelse continue;
        const permille = progress.permille();
        // Opened but nothing read yet is no reading
        if (permille == 0 and !progress.completed) continue;

        const time = if (progress.completed and progress.completed_at > 0)
            progress.completed_at
        else if (progress.moved > 0) progress.moved else progress.opened;

        if (last.get(book.id)) |previous| {
            if (previous.permille == permille) continue;
            // The font size changed, not the reading: same moment, the page numbers moved
            if (time <= previous.time) continue;
        }
        try new.append(allocator, .{ .time = time, .book = book.id, .permille = permille, .title = book.title });
    }
    std.mem.sort(Record, new.items, {}, earlierFirst);
    return new.toOwnedSlice(allocator);
}

fn earlierFirst(_: void, a: Record, b: Record) bool {
    return a.time < b.time;
}

/// A record together with how far the book was before it, for showing what changed
pub const Step = struct {
    record: Record,
    /// Null for the first record of a book
    from: ?u16,
};

/// The records with their previous progress, the latest first
pub fn steps(allocator: std.mem.Allocator, records: []const Record) ![]Step {
    const sorted = try allocator.dupe(Record, records);
    defer allocator.free(sorted);
    std.mem.sort(Record, sorted, {}, earlierFirst);

    var last: std.AutoHashMapUnmanaged(i64, u16) = .empty;
    defer last.deinit(allocator);
    const list = try allocator.alloc(Step, sorted.len);
    for (sorted, 0..) |record, i| {
        list[sorted.len - 1 - i] = .{ .record = record, .from = last.get(record.book) };
        try last.put(allocator, record.book, record.permille);
    }
    return list;
}

pub const Activity = struct {
    /// Days with reading in the 30 days up to today
    days_last_30: usize = 0,
    /// Days in a row with reading, up to today or yesterday
    streak: usize = 0,
    /// Days with reading ever recorded
    days: usize = 0,
    /// The day the journal starts, null when empty
    since: ?dates.Day = null,
};

pub fn activity(allocator: std.mem.Allocator, records: []const Record, today: dates.Day, utc_offset: i32) !Activity {
    var days: std.AutoHashMapUnmanaged(dates.Day, void) = .empty;
    defer days.deinit(allocator);
    var result: Activity = .{};
    for (records) |record| {
        const day = dates.dayOf(record.time, utc_offset);
        try days.put(allocator, day, {});
        if (result.since == null or day < result.since.?) result.since = day;
    }
    result.days = days.count();

    var it = days.keyIterator();
    while (it.next()) |day| {
        if (day.* > today - 30 and day.* <= today) result.days_last_30 += 1;
    }

    // A streak still counts when today has no reading yet
    var day = if (days.contains(today)) today else today - 1;
    while (days.contains(day)) : (day -= 1) result.streak += 1;
    return result;
}

/// The days with reading among the last `n` (at most 32) up to today: bit i is set when
/// there was reading `i` days ago
pub fn recentDays(records: []const Record, today: dates.Day, utc_offset: i32, n: u5) u32 {
    var mask: u32 = 0;
    for (records) |record| {
        const ago = today - dates.dayOf(record.time, utc_offset);
        if (ago >= 0 and ago < n) mask |= @as(u32, 1) << @intCast(ago);
    }
    return mask;
}

/// The number of days with reading in `year`
pub fn readingDaysIn(allocator: std.mem.Allocator, records: []const Record, year: i32, utc_offset: i32) !usize {
    var days: std.AutoHashMapUnmanaged(dates.Day, void) = .empty;
    defer days.deinit(allocator);
    for (records) |record| {
        const day = dates.dayOf(record.time, utc_offset);
        if (dates.dateOf(day).year == year) try days.put(allocator, day, {});
    }
    return days.count();
}

/// How a book is being read, from its records
pub const Pace = struct {
    /// The first record of the book, and how far it was then
    since: dates.Day,
    since_permille: u16,
    /// The latest record
    last: dates.Day,
    permille: u16,
    /// Thousandths read per day over the last month (or since the first record)
    per_day: f32,
    /// When the book would be finished at that pace, null when it does not move
    finish: ?dates.Day,
};

/// Days the pace is measured over
const pace_window = 30;

pub fn pace(records: []const Record, book: i64, today: dates.Day, utc_offset: i32) ?Pace {
    var first: ?Record = null;
    var last: ?Record = null;
    for (records) |record| {
        if (record.book != book) continue;
        if (first == null or record.time < first.?.time) first = record;
        if (last == null or record.time >= last.?.time) last = record;
    }
    const start = first orelse return null;
    const end = last.?;

    // The pace starts from the last record before the window, so a month of reading counts
    // fully and the time without reading since counts too
    const window_start = today - pace_window;
    var base = start;
    for (records) |record| {
        if (record.book != book) continue;
        if (dates.dayOf(record.time, utc_offset) < window_start and record.time > base.time) base = record;
    }

    const end_day = dates.dayOf(end.time, utc_offset);
    const base_day = dates.dayOf(base.time, utc_offset);
    const span: f32 = @floatFromInt(@max(1, today - base_day));
    const gained: f32 = @floatFromInt(@as(i32, end.permille) - @as(i32, base.permille));
    const per_day = @max(0, gained / span);

    const finish: ?dates.Day = if (end.permille >= 1000)
        end_day
    else if (per_day > 0)
        today + @as(dates.Day, @intFromFloat(@ceil(@as(f32, @floatFromInt(1000 - end.permille)) / per_day)))
    else
        null;
    return .{
        .since = dates.dayOf(start.time, utc_offset),
        .since_permille = start.permille,
        .last = end_day,
        .permille = end.permille,
        .per_day = per_day,
        .finish = finish,
    };
}

/// Reads the journal file, an empty journal if there is none.
/// Through libc: Zig's own file layer makes system calls the reader's kernel lacks.
pub fn load(allocator: std.mem.Allocator, path: [:0]const u8) ![]Record {
    const file = std.c.fopen(path.ptr, "rb") orelse return &.{};
    defer _ = std.c.fclose(file);

    var text: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const read = std.c.fread(&buf, 1, buf.len, file);
        if (read == 0) break;
        try text.appendSlice(allocator, buf[0..read]);
    }
    return parse(allocator, text.items);
}

/// Adds `records` at the end of the journal file
pub fn append(path: [:0]const u8, records: []const Record) !void {
    if (records.len == 0) return;
    const file = std.c.fopen(path.ptr, "ab") orelse return error.CannotWriteJournal;
    defer _ = std.c.fclose(file);

    for (records) |record| {
        var buf: [320]u8 = undefined;
        const line = try format(record, &buf);
        if (std.c.fwrite(line.ptr, 1, line.len, file) != line.len) return error.CannotWriteJournal;
    }
}

const day_seconds = std.time.s_per_day;
const now: i64 = 1792698480; // 2026-10-22 19:48 UTC

test "recentDays marks the days with reading" {
    const today = dates.dayOf(now, 0);
    const records = [_]Record{
        .{ .time = now, .book = 1, .permille = 10, .title = "" },
        .{ .time = now - 2 * day_seconds, .book = 1, .permille = 5, .title = "" },
        .{ .time = now - 40 * day_seconds, .book = 1, .permille = 1, .title = "" },
    };
    try std.testing.expectEqual(@as(u32, 0b101), recentDays(&records, today, 0, 30));
    try std.testing.expectEqual(2, try readingDaysIn(std.testing.allocator, records[0..2], 2026, 0));
}

test "pace measures the last month and estimates the end" {
    const today = dates.dayOf(now, 0);
    const records = [_]Record{
        .{ .time = now - 60 * day_seconds, .book = 1, .permille = 100, .title = "" },
        .{ .time = now - 31 * day_seconds, .book = 1, .permille = 200, .title = "" },
        .{ .time = now - 10 * day_seconds, .book = 1, .permille = 500, .title = "" },
        .{ .time = now - 1 * day_seconds, .book = 1, .permille = 500, .title = "" },
        .{ .time = now, .book = 2, .permille = 900, .title = "" },
    };
    const book = pace(&records, 1, today, 0).?;
    try std.testing.expectEqual(today - 60, book.since);
    try std.testing.expectEqual(100, book.since_permille);
    // 300 thousandths in the 31 days since the record before the window
    try std.testing.expectApproxEqAbs(@as(f32, 300.0 / 31.0), book.per_day, 0.001);
    // 500 left at about 9.7 a day
    try std.testing.expectEqual(today + 52, book.finish.?);

    // One record only: no pace yet
    const other = pace(&records, 2, today, 0).?;
    try std.testing.expectEqual(null, other.finish);
    try std.testing.expectEqual(null, pace(&records, 3, today, 0));
}

test "parse reads lines and skips broken ones" {
    const text = "1792628940\t9\t1000\tLe Temps d'après\nbroken line\n1792698480\t7\t10\tDungeon Crawler Carl\r\n";
    const records = try parse(std.testing.allocator, text);
    defer std.testing.allocator.free(records);
    try std.testing.expectEqual(2, records.len);
    try std.testing.expectEqualDeep(Record{ .time = 1792628940, .book = 9, .permille = 1000, .title = "Le Temps d'après" }, records[0]);
    try std.testing.expectEqualStrings("Dungeon Crawler Carl", records[1].title);
}

test "format writes what parse reads, without tabs in titles" {
    var buf: [320]u8 = undefined;
    const line = try format(.{ .time = 1, .book = 2, .permille = 3, .title = "A\tB" }, &buf);
    try std.testing.expectEqualStrings("1\t2\t3\tA B\n", line);
}

test "changes records new progress only" {
    const books = [_]library.Book{
        .{ .id = 7, .title = "Dungeon Crawler Carl", .author = "", .progress = .{ .page = 5, .pages = 458, .opened = now - 300, .moved = now } },
        .{ .id = 8, .title = "Petit crapahut", .author = "", .progress = .{ .opened = now - 8 * day_seconds } },
        .{ .id = 9, .title = "Le Temps d'après", .author = "", .progress = .{ .page = 225, .pages = 225, .moved = now - day_seconds, .completed = true, .completed_at = now - day_seconds } },
        .{ .id = 10, .title = "Unread", .author = "" },
    };

    const first = try changes(std.testing.allocator, &.{}, &books);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(2, first.len);
    try std.testing.expectEqual(9, first[0].book);
    try std.testing.expectEqual(now - day_seconds, first[0].time);

    // Nothing changed since
    const again = try changes(std.testing.allocator, first, &books);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqual(0, again.len);

    // Read further
    var later = books;
    later[0].progress.?.page = 50;
    later[0].progress.?.moved = now + day_seconds;
    const further = try changes(std.testing.allocator, first, &later);
    defer std.testing.allocator.free(further);
    try std.testing.expectEqual(1, further.len);
    try std.testing.expectEqual(109, further[0].permille);
}

test "changes ignores page numbers that moved with the font size" {
    const before = [_]Record{.{ .time = now, .book = 7, .permille = 10, .title = "" }};
    const books = [_]library.Book{
        .{ .id = 7, .title = "", .author = "", .progress = .{ .page = 6, .pages = 500, .moved = now } },
    };
    const new = try changes(std.testing.allocator, &before, &books);
    defer std.testing.allocator.free(new);
    try std.testing.expectEqual(0, new.len);
}

test "steps give what each record changed, the latest first" {
    const records = [_]Record{
        .{ .time = now - 2 * day_seconds, .book = 9, .permille = 400, .title = "" },
        .{ .time = now, .book = 9, .permille = 1000, .title = "" },
        .{ .time = now - day_seconds, .book = 7, .permille = 10, .title = "" },
    };
    const list = try steps(std.testing.allocator, &records);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(1000, list[0].record.permille);
    try std.testing.expectEqual(400, list[0].from.?);
    try std.testing.expectEqual(null, list[2].from);
}

test "activity counts reading days and the current streak" {
    const today = dates.dayOf(now, 0);
    const records = [_]Record{
        .{ .time = now - 40 * day_seconds, .book = 1, .permille = 100, .title = "" },
        .{ .time = now - 2 * day_seconds, .book = 1, .permille = 200, .title = "" },
        .{ .time = now - day_seconds, .book = 1, .permille = 300, .title = "" },
        .{ .time = now - day_seconds + 60, .book = 2, .permille = 50, .title = "" },
    };
    const result = try activity(std.testing.allocator, &records, today, 0);
    try std.testing.expectEqual(3, result.days);
    try std.testing.expectEqual(2, result.days_last_30);
    // Read yesterday and the day before, not yet today
    try std.testing.expectEqual(2, result.streak);
    try std.testing.expectEqual(today - 40, result.since.?);
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

test "append and load keep the journal in a file" {
    var template = "/tmp/pb-stats-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/journal.tsv", .{dir}, 0);

    const empty = try load(std.testing.allocator, path);
    try std.testing.expectEqual(0, empty.len);

    try append(path, &.{.{ .time = 1, .book = 2, .permille = 3, .title = "First" }});
    try append(path, &.{.{ .time = 4, .book = 5, .permille = 6, .title = "Second" }});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const records = try load(arena.allocator(), path);
    try std.testing.expectEqual(2, records.len);
    try std.testing.expectEqualStrings("Second", records[1].title);
}
