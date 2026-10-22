//! What the start screen and its lists show, computed from the books of the library.

const std = @import("std");
const library = @import("library.zig");
const dates = @import("dates.zig");
const Book = library.Book;

pub const Shelf = enum {
    /// Opened and not finished
    reading,
    finished,
    /// Never opened
    unread,
};

pub fn shelfOf(book: Book) Shelf {
    const progress = book.progress orelse return .unread;
    return if (progress.completed) .finished else .reading;
}

pub const Summary = struct {
    books: usize = 0,
    reading: usize = 0,
    finished: usize = 0,
    unread: usize = 0,
    /// Books with a file on the reader, the others are only in the cloud
    on_device: usize = 0,
};

pub fn summarize(books: []const Book) Summary {
    var summary: Summary = .{ .books = books.len };
    for (books) |book| {
        switch (shelfOf(book)) {
            .reading => summary.reading += 1,
            .finished => summary.finished += 1,
            .unread => summary.unread += 1,
        }
        if (book.on_device) summary.on_device += 1;
    }
    return summary;
}

/// The books of a shelf, the most recent first: last opened for books being read,
/// last finished for finished ones, last added for the others
pub fn shelf(allocator: std.mem.Allocator, books: []const Book, which: Shelf) ![]Book {
    var list: std.ArrayList(Book) = .empty;
    for (books) |book| {
        if (shelfOf(book) == which) try list.append(allocator, book);
    }
    const items = try list.toOwnedSlice(allocator);
    std.mem.sort(Book, items, which, newerFirst);
    return items;
}

fn newerFirst(which: Shelf, a: Book, b: Book) bool {
    return sortTime(which, a) > sortTime(which, b);
}

fn sortTime(which: Shelf, book: Book) i64 {
    return switch (which) {
        .reading => if (book.progress) |p| @max(p.opened, p.moved) else 0,
        .finished => if (book.progress) |p| p.completed_at else 0,
        .unread => book.added,
    };
}

pub const MonthCount = struct { month: dates.Month, count: usize };

/// How many books were finished in each month, the latest month first
pub fn finishedPerMonth(allocator: std.mem.Allocator, books: []const Book, utc_offset: i32) ![]MonthCount {
    var counts: std.AutoArrayHashMapUnmanaged(dates.Month, usize) = .empty;
    defer counts.deinit(allocator);
    for (books) |book| {
        const progress = book.progress orelse continue;
        if (!progress.completed or progress.completed_at == 0) continue;
        const entry = try counts.getOrPutValue(allocator, dates.monthOf(dates.dayOf(progress.completed_at, utc_offset)), 0);
        entry.value_ptr.* += 1;
    }
    return sortedMonths(allocator, counts);
}

/// How many books were added to the library in each month, the latest month first
pub fn addedPerMonth(allocator: std.mem.Allocator, books: []const Book, utc_offset: i32) ![]MonthCount {
    var counts: std.AutoArrayHashMapUnmanaged(dates.Month, usize) = .empty;
    defer counts.deinit(allocator);
    for (books) |book| {
        if (book.added == 0) continue;
        const entry = try counts.getOrPutValue(allocator, dates.monthOf(dates.dayOf(book.added, utc_offset)), 0);
        entry.value_ptr.* += 1;
    }
    return sortedMonths(allocator, counts);
}

fn sortedMonths(allocator: std.mem.Allocator, counts: std.AutoArrayHashMapUnmanaged(dates.Month, usize)) ![]MonthCount {
    const list = try allocator.alloc(MonthCount, counts.count());
    for (counts.keys(), counts.values(), 0..) |month, count, i| list[i] = .{ .month = month, .count = count };
    std.mem.sort(MonthCount, list, {}, struct {
        fn later(_: void, a: MonthCount, b: MonthCount) bool {
            return a.month > b.month;
        }
    }.later);
    return list;
}

/// What a year of reading was
pub const Year = struct {
    finished: usize = 0,
    /// Pages of the books finished, for those whose number of pages is known
    pages: u64 = 0,
    /// The finished book with the most pages
    longest: ?Book = null,
    /// The author with the most books finished, if one has more than one
    top_author: ?NameCount = null,
    /// Books finished in each month, January first
    per_month: [12]usize = @splat(0),
};

/// The day a book was finished, null if not finished or the date is unknown
pub fn finishedDay(book: Book, utc_offset: i32) ?dates.Day {
    const progress = book.progress orelse return null;
    if (!progress.completed or progress.completed_at == 0) return null;
    return dates.dayOf(progress.completed_at, utc_offset);
}

pub fn yearSummary(allocator: std.mem.Allocator, books: []const Book, year: i32, utc_offset: i32) !Year {
    var result: Year = .{};
    var finished: std.ArrayList(Book) = .empty;
    defer finished.deinit(allocator);
    for (books) |book| {
        const finished_on = finishedDay(book, utc_offset) orelse continue;
        const date = dates.dateOf(finished_on);
        if (date.year != year) continue;
        try finished.append(allocator, book);
        result.finished += 1;
        result.per_month[date.month - 1] += 1;
        const pages = book.progress.?.pages;
        result.pages += pages;
        if (pages > 0 and (result.longest == null or pages > result.longest.?.progress.?.pages)) result.longest = book;
    }
    const by_author = try authors(allocator, finished.items);
    defer allocator.free(by_author);
    if (by_author.len > 0 and by_author[0].count > 1) result.top_author = by_author[0];
    return result;
}

/// The years books were finished in, the latest first
pub fn finishedYears(allocator: std.mem.Allocator, books: []const Book, utc_offset: i32) ![]i32 {
    var years: std.ArrayList(i32) = .empty;
    for (books) |book| {
        const finished_on = finishedDay(book, utc_offset) orelse continue;
        const year = dates.dateOf(finished_on).year;
        if (std.mem.indexOfScalar(i32, years.items, year) == null) try years.append(allocator, year);
    }
    std.mem.sort(i32, years.items, {}, std.sort.desc(i32));
    return years.toOwnedSlice(allocator);
}

/// Where a yearly goal stands on `today`
pub const GoalPace = struct {
    /// Books that should be finished by now to reach the goal at a steady pace
    expected: usize,
    /// Books ahead of that pace, negative when behind
    ahead: i64,
};

pub fn goalPace(finished: usize, goal: usize, today: dates.Day) GoalPace {
    const year = dates.dateOf(today).year;
    const elapsed: usize = @intCast(today - dates.yearStart(year) + 1);
    const expected = goal * elapsed / @as(usize, @intCast(dates.daysInYear(year)));
    return .{ .expected = expected, .ahead = @as(i64, @intCast(finished)) - @as(i64, @intCast(expected)) };
}

pub const NameCount = struct { name: []const u8, count: usize };

/// Authors by number of books, then by name
pub fn authors(allocator: std.mem.Allocator, books: []const Book) ![]NameCount {
    return countBy(allocator, books, struct {
        fn key(book: Book) []const u8 {
            return book.author;
        }
    }.key);
}

/// File formats by number of books
pub fn formats(allocator: std.mem.Allocator, books: []const Book) ![]NameCount {
    return countBy(allocator, books, struct {
        fn key(book: Book) []const u8 {
            return book.format;
        }
    }.key);
}

/// Series by number of books
pub fn series(allocator: std.mem.Allocator, books: []const Book) ![]NameCount {
    return countBy(allocator, books, struct {
        fn key(book: Book) []const u8 {
            return book.series;
        }
    }.key);
}

fn countBy(allocator: std.mem.Allocator, books: []const Book, comptime key: fn (Book) []const u8) ![]NameCount {
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(allocator);
    for (books) |book| {
        const name = key(book);
        if (name.len == 0) continue;
        const entry = try counts.getOrPutValue(allocator, name, 0);
        entry.value_ptr.* += 1;
    }
    const list = try allocator.alloc(NameCount, counts.count());
    for (counts.keys(), counts.values(), 0..) |name, count, i| list[i] = .{ .name = name, .count = count };
    std.mem.sort(NameCount, list, {}, struct {
        fn more(_: void, a: NameCount, b: NameCount) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.more);
    return list;
}

const day = std.time.s_per_day;
const now: i64 = 1792698480; // 2026-10-22 19:48 UTC

fn testBooks() [5]Book {
    return .{
        .{ .id = 7, .title = "Dungeon Crawler Carl T1", .author = "Matt Dinniman", .added = now - 9 * day, .progress = .{ .page = 5, .pages = 458, .opened = now - 300, .moved = now } },
        .{ .id = 8, .title = "Petit crapahut", .author = "Stéphane Encel", .added = now - 9 * day, .progress = .{ .opened = now - 8 * day } },
        .{ .id = 9, .title = "Le Temps d'après", .author = "Jean Hegland", .added = now - 9 * day, .progress = .{ .page = 225, .pages = 225, .opened = now - day, .moved = now - day, .completed = true, .completed_at = now - day } },
        .{ .id = 10, .title = "Les désarmantes", .author = "Caroline Bouffault", .added = now - 9 * day, .on_device = false },
        .{ .id = 11, .title = "Le Problème à trois corps", .author = "Liu Cixin", .series = "Trois corps", .added = now - 8 * day, .format = "epub" },
    };
}

test "summarize counts the shelves" {
    const books = testBooks();
    const summary = summarize(&books);
    try std.testing.expectEqual(Summary{ .books = 5, .reading = 2, .finished = 1, .unread = 2, .on_device = 4 }, summary);
}

test "shelf puts the most recent first" {
    const books = testBooks();
    const reading = try shelf(std.testing.allocator, &books, .reading);
    defer std.testing.allocator.free(reading);
    try std.testing.expectEqual(2, reading.len);
    try std.testing.expectEqual(7, reading[0].id);

    const unread = try shelf(std.testing.allocator, &books, .unread);
    defer std.testing.allocator.free(unread);
    try std.testing.expectEqual(11, unread[0].id);
}

test "finished and added books are counted per month" {
    const books = testBooks();
    const finished = try finishedPerMonth(std.testing.allocator, &books, 0);
    defer std.testing.allocator.free(finished);
    try std.testing.expectEqual(1, finished.len);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Oct 2026", dates.formatMonth(&buf, finished[0].month));

    const added = try addedPerMonth(std.testing.allocator, &books, 0);
    defer std.testing.allocator.free(added);
    try std.testing.expectEqual(5, added[0].count);
}

test "authors are sorted by number of books, then by name" {
    var books = testBooks();
    books[1].author = "Liu Cixin";
    const list = try authors(std.testing.allocator, &books);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqualStrings("Liu Cixin", list[0].name);
    try std.testing.expectEqual(2, list[0].count);
    try std.testing.expectEqualStrings("Caroline Bouffault", list[1].name);
}

test "a year sums up the books finished in it" {
    var books = testBooks();
    books[0].progress.?.completed = true;
    books[0].progress.?.completed_at = now - 400 * day;
    const year = try yearSummary(std.testing.allocator, &books, 2026, 0);
    try std.testing.expectEqual(1, year.finished);
    try std.testing.expectEqual(225, year.pages);
    try std.testing.expectEqual(9, year.longest.?.id);
    try std.testing.expectEqual(1, year.per_month[9]);
    try std.testing.expectEqual(null, year.top_author);

    const years = try finishedYears(std.testing.allocator, &books, 0);
    defer std.testing.allocator.free(years);
    try std.testing.expectEqualSlices(i32, &.{ 2026, 2025 }, years);
}

test "goalPace compares with a steady pace over the year" {
    // 2026-10-22 is day 295 of 365: 24 books a year means 19 by now
    const today = dates.dayOf(now, 0);
    try std.testing.expectEqual(GoalPace{ .expected = 19, .ahead = 1 }, goalPace(20, 24, today));
    try std.testing.expectEqual(GoalPace{ .expected = 19, .ahead = -4 }, goalPace(15, 24, today));
    try std.testing.expectEqual(@as(usize, 0), goalPace(0, 12, dates.yearStart(2026)).expected);
}

test "books without a series are not a series" {
    const books = testBooks();
    const list = try series(std.testing.allocator, &books);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(1, list.len);
}
