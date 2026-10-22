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

test "books without a series are not a series" {
    const books = testBooks();
    const list = try series(std.testing.allocator, &books);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(1, list.len);
}
