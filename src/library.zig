//! Reads the books and their reading progress from the reader's library database.
//! The database is only ever read.
//!
//! The library (explorer.app) keeps it in WAL mode: recent changes live in
//! "explorer-3.db-wal" next to it until they are written back. SQLite reads both, so a copy
//! of the database for testing must include the -wal file, or it is days behind.

const std = @import("std");
const c = @import("sqlite");

/// Where the reader keeps its library
pub const default_path = "/mnt/ext1/system/explorer-3/explorer-3.db";

pub const Book = struct {
    id: i64,
    title: []const u8,
    author: []const u8,
    series: []const u8 = "",
    /// When it was added to the library, 0 if unknown
    added: i64 = 0,
    /// File extension of its first file, e.g. "epub"
    format: []const u8 = "",
    /// Whether a file of it is on the reader, not only in the PocketBook cloud
    on_device: bool = true,
    /// Null until the book was first opened
    progress: ?Progress = null,
};

pub const Progress = struct {
    /// Current page and number of pages, in the layout the book was last shown in.
    /// They change with the font size, so only their ratio means something. 0 if unknown.
    page: u32 = 0,
    pages: u32 = 0,
    /// Last time the book was opened
    opened: i64 = 0,
    /// Last time the reading position changed
    moved: i64 = 0,
    completed: bool = false,
    /// When the book was marked as read. Only meaningful when `completed`: for other books
    /// the library fills in the time it first opened them.
    completed_at: i64 = 0,

    /// Read so far, in thousandths
    pub fn permille(progress: Progress) u16 {
        if (progress.completed) return 1000;
        if (progress.pages == 0) return 0;
        return @intCast(@min(1000, @as(u64, progress.page) * 1000 / progress.pages));
    }
};

/// Books whose author is one of these are manuals that came with the reader
const manual_authors = [_][]const u8{ "Vivlio", "PocketBook" };

const query =
    \\SELECT b.id, b.title, b.author, b.series, b.ts_added,
    \\  s.cpage, s.npage, s.opentime, s.position_ts, s.completed, s.completed_ts,
    \\  (SELECT f.ext FROM files f WHERE f.book_id = b.id ORDER BY f.storageid LIMIT 1),
    \\  EXISTS (SELECT 1 FROM files f JOIN storages st ON st.id = f.storageid
    \\          WHERE f.book_id = b.id AND st.name = 'InternalStorage'),
    \\  s.bookid IS NOT NULL
    \\FROM books_impl b
    \\LEFT JOIN books_settings s ON s.bookid = b.id
    \\  AND s.profileid = (SELECT MIN(id) FROM profiles)
    \\WHERE b.hidden = 0
    \\  AND EXISTS (SELECT 1 FROM files f WHERE f.book_id = b.id)
;

/// Reads all books of the library. Hidden books, books without a file and the reader's own
/// manuals are left out. All strings are allocated with `allocator`, pass an arena.
pub fn load(allocator: std.mem.Allocator, path: [:0]const u8) ![]Book {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) return error.CannotOpenLibrary;
    return loadFrom(allocator, db.?);
}

pub fn loadFrom(allocator: std.mem.Allocator, db: *c.sqlite3) ![]Book {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query, -1, &statement, null) != c.SQLITE_OK) return error.UnknownLibraryFormat;
    defer _ = c.sqlite3_finalize(statement);
    const stmt = statement.?;

    var books: std.ArrayList(Book) = .empty;
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => break,
            else => return error.CannotReadLibrary,
        }

        const author = try text(allocator, stmt, 2);
        if (isManual(author)) continue;

        var book: Book = .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .title = try text(allocator, stmt, 1),
            .author = author,
            .series = try text(allocator, stmt, 3),
            .added = c.sqlite3_column_int64(stmt, 4),
            .format = try text(allocator, stmt, 11),
            .on_device = c.sqlite3_column_int(stmt, 12) != 0,
        };
        // A settings row exists once the book was opened, or synchronized from the cloud
        const opened = c.sqlite3_column_int64(stmt, 7);
        const completed = c.sqlite3_column_int(stmt, 9) != 0;
        if (c.sqlite3_column_int(stmt, 13) != 0 and (opened > 0 or completed)) {
            book.progress = .{
                .page = count(stmt, 5),
                .pages = count(stmt, 6),
                .opened = opened,
                .moved = c.sqlite3_column_int64(stmt, 8),
                .completed = completed,
                .completed_at = c.sqlite3_column_int64(stmt, 10),
            };
        }
        try books.append(allocator, book);
    }
    return books.toOwnedSlice(allocator);
}

fn isManual(author: []const u8) bool {
    const trimmed = std.mem.trim(u8, author, " ");
    for (manual_authors) |name| {
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

fn text(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return allocator.dupe(u8, std.mem.trim(u8, ptr[0..len], " "));
}

fn count(stmt: *c.sqlite3_stmt, column: c_int) u32 {
    return std.math.cast(u32, c.sqlite3_column_int64(stmt, column)) orelse 0;
}

/// The part of the library's schema the app reads, with a few books like a real reader has
const test_library =
    \\CREATE TABLE profiles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
    \\CREATE TABLE storages(id INTEGER PRIMARY KEY, type INTEGER, name TEXT, sync_account_id INTEGER);
    \\CREATE TABLE books_impl(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, author TEXT, series TEXT,
    \\  ts_added INTEGER, hidden INTEGER INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE books_settings(bookid INTEGER, profileid INTEGER, position TEXT, position_ts INTEGER,
    \\  cpage INTEGER, npage INTEGER, opentime INTEGER, completed INTEGER, completed_ts INTEGER,
    \\  PRIMARY KEY(bookid, profileid));
    \\CREATE TABLE files(id INTEGER PRIMARY KEY AUTOINCREMENT, storageid INTEGER, book_id INTEGER,
    \\  filename TEXT, ext TEXT);
    \\INSERT INTO profiles VALUES (1, 'default');
    \\INSERT INTO storages VALUES (1, 1, 'InternalStorage', NULL), (2, 2, 'PocketbookCloud', 1);
    \\INSERT INTO books_impl VALUES
    \\  (1, 'Manuel Light HD Color', 'Vivlio', '', 1792000000, 0),
    \\  (2, 'Extraits 2026', 'Collectif ', '', 1792000000, 0),
    \\  (7, 'Dungeon Crawler Carl T1', 'Matt Dinniman', '', 1792015000, 0),
    \\  (8, 'Petit crapahut', 'Stéphane Encel', '', 1792015000, 0),
    \\  (9, 'Le Temps d''après', 'Jean Hegland', '', 1792015000, 0),
    \\  (10, 'Les désarmantes', 'Caroline Bouffault', NULL, 1792015000, 0),
    \\  (11, 'Le Problème à trois corps', 'Liu Cixin', 'Trois corps', 1792060000, 0),
    \\  (12, 'Hidden', 'Someone', '', 1792060000, 1);
    \\INSERT INTO books_settings VALUES
    \\  (1, 1, NULL, NULL, NULL, NULL, 1792000000, NULL, 1792000000),
    \\  (2, 1, NULL, NULL, NULL, NULL, NULL, NULL, 1792000000),
    \\  (7, 1, 'epubcfi', 1792698480, 5, 458, 1792698180, 0, 1792016000),
    \\  (8, 1, 'epubcfi', 1792059000, NULL, NULL, 1792059000, NULL, 1792059000),
    \\  (9, 1, 'epubcfi', 1792628940, 225, 225, 1792628580, 1, 1792628940);
    \\INSERT INTO files VALUES
    \\  (1, 1, 1, 'manual.pdf', 'pdf'),
    \\  (11, 1, 8, 'crapahut.epub', 'epub'),
    \\  (12, 2, 7, 'dcc-cloud.epub', 'epub'),
    \\  (13, 1, 7, 'dcc.epub', 'epub'),
    \\  (14, 1, 9, 'temps.epub', 'epub'),
    \\  (15, 2, 10, 'desarmantes.epub', 'epub'),
    \\  (18, 1, 11, 'trois-corps.epub', 'epub'),
    \\  (19, 1, 12, 'hidden.epub', 'epub');
;

fn loadTestLibrary(allocator: std.mem.Allocator) ![]Book {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, test_library, null, null, null));
    return loadFrom(allocator, db.?);
}

fn find(books: []const Book, id: i64) ?Book {
    for (books) |book| {
        if (book.id == id) return book;
    }
    return null;
}

test "load leaves out manuals, hidden books and books without a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const books = try loadTestLibrary(arena.allocator());

    try std.testing.expectEqual(5, books.len);
    try std.testing.expectEqual(null, find(books, 1));
    try std.testing.expectEqual(null, find(books, 2));
    try std.testing.expectEqual(null, find(books, 12));
}

test "load reads progress, completion and where the files are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const books = try loadTestLibrary(arena.allocator());

    const reading = find(books, 7).?;
    try std.testing.expectEqualStrings("Matt Dinniman", reading.author);
    try std.testing.expectEqualStrings("epub", reading.format);
    try std.testing.expect(reading.on_device);
    try std.testing.expectEqual(10, reading.progress.?.permille());
    try std.testing.expect(!reading.progress.?.completed);

    const finished = find(books, 9).?;
    try std.testing.expect(finished.progress.?.completed);
    try std.testing.expectEqual(1792628940, finished.progress.?.completed_at);
    try std.testing.expectEqual(1000, finished.progress.?.permille());

    // Opened, but no page known yet
    const opened = find(books, 8).?;
    try std.testing.expectEqual(0, opened.progress.?.permille());

    const in_cloud = find(books, 10).?;
    try std.testing.expect(!in_cloud.on_device);
    try std.testing.expectEqual(null, in_cloud.progress);
    try std.testing.expectEqualStrings("", in_cloud.series);

    try std.testing.expectEqualStrings("Trois corps", find(books, 11).?.series);
}

test "load works on the database of a real reader, if one is given" {
    // PB_STATS_TEST_DB=/path/to/explorer-3.db zig build test
    const path = std.c.getenv("PB_STATS_TEST_DB") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const books = try load(arena.allocator(), std.mem.span(path));
    try std.testing.expect(books.len > 0);
}
