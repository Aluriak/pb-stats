//! Reading Stats: what the reader's library knows about your reading, on the reader.

const std = @import("std");
const pb = @import("c");

const library = @import("library.zig");
const journal = @import("journal.zig");
const stats = @import("stats.zig");
const dates = @import("dates.zig");
const update = @import("update.zig");
const Policy = @import("update_check.zig").Policy;
const i18n = @import("i18n.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;
const showError = pocketbook.showError;
const t = i18n.t;

/// A line of a list: a title, and a second, grey line under it
const Row = struct {
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    /// What opening it does, if anything
    opens: ?Action = null,
    /// A heading between parts of a list, not a book
    heading: bool = false,
    /// Drawn on the second line, after the detail
    chart: Chart = .none,
};

const Chart = union(enum) {
    none,
    /// A bar as long as `value` is of `max`
    bar: struct { value: usize, max: usize },
    /// The days of the last month, the oldest first: bit i is set when there was reading
    /// i days ago
    days: u32,
};

/// The screens of the app
const Page = union(enum) {
    start,
    reading,
    finished,
    unread,
    activity,
    library,
    /// The sheet of a book, by its index in `books`
    book: usize,
    year: i32,
};

/// What opening a row does: open a page, look for an update, change the language or the goal
const Action = union(enum) { page: Page, update, language, goal };

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

/// The app's settings: "updates=stable" (default), "all" (nightly builds too) or "off";
/// "language=auto" (default, the reader's), "fr" or "en"
const config_path = "/mnt/ext1/system/config/reading-stats.cfg";

var language: i18n.Choice = .auto;
/// Books to finish this year, 0 for no goal
var goal: usize = 0;

fn readGoal() usize {
    const config = pb.OpenConfig(config_path, null) orelse return 0;
    defer pb.CloseConfigNoSave(config);
    return @intCast(@max(0, pb.ReadInt(config, "goal", 0)));
}

/// What the user types as goal
var goal_text: [8]u8 = undefined;
var goal_title: [96]u8 = undefined;

fn openGoalKeyboard() void {
    const title = i18n.fmt(&goal_title, .goal_keyboard, .{dates.dateOf(today).year});
    goal_text = @splat(0);
    if (goal > 0) _ = std.fmt.bufPrint(goal_text[0 .. goal_text.len - 1], "{d}", .{goal}) catch {};
    pb.OpenKeyboard(title.ptr, &goal_text, goal_text.len - 1, pb.KBD_NUMERIC, goalEntered);
}

/// Called by InkView when the keyboard closes, without a text if it was cancelled
fn goalEntered(typed: [*c]u8) callconv(.c) void {
    if (typed == null) return showList();
    const text = std.mem.trim(u8, std.mem.span(typed), " ");
    goal = std.fmt.parseInt(u16, text, 10) catch 0;
    if (pb.OpenConfig(config_path, null)) |config| {
        pb.WriteInt(config, "goal", @intCast(goal));
        _ = pb.SaveConfig(config);
        pb.CloseConfig(config);
    }
    rebuildStart();
}

extern "c" fn currentLang() ?[*:0]const u8;

fn readLanguage() i18n.Choice {
    const config = pb.OpenConfig(config_path, null) orelse return .auto;
    defer pb.CloseConfigNoSave(config);
    return i18n.Choice.parse(std.mem.span(pb.ReadString(config, "language", "auto")));
}

fn applyLanguage() void {
    i18n.lang = language.resolve(std.mem.span(currentLang() orelse "en"));
    _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, t(.app_title), null);
}

/// Goes to the next language, keeps it and shows the start screen in it
fn changeLanguage() void {
    language = language.next();
    if (pb.OpenConfig(config_path, null)) |config| {
        pb.WriteString(config, "language", @tagName(language));
        _ = pb.SaveConfig(config);
        pb.CloseConfig(config);
    }
    applyLanguage();
    rebuildStart();
}

/// Builds the start screen again, the only one open, keeping the selected row
fn rebuildStart() void {
    const pos = screens.items[0].pos;
    while (screens.pop()) |screen| {
        var closed = screen;
        closed.arena.deinit();
    }
    pushScreen(.start) catch {
        pb.CloseApp();
        return;
    };
    screens.items[0].pos = @min(pos, startRowCount() - 1);
    showList();
}

/// Which updates the start screen offers
var update_policy: Policy = .off;

fn readUpdatePolicy() Policy {
    if (!update.enabled) return .off;
    const config = pb.OpenConfig(config_path, null) orelse return .stable;
    defer pb.CloseConfigNoSave(config);
    return Policy.parse(std.mem.span(pb.ReadString(config, "updates", "stable")));
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
            language = readLanguage();
            applyLanguage();
            goal = readGoal();

            item_height = @divTrunc(pb.ScreenHeight(), 10);
            padding = @divTrunc(item_height, 8);
            title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 4), 1);
            detail_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(item_height, 5), 1);
            heading_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 5), 1);

            update_policy = readUpdatePolicy();
            loadData() catch |err| {
                showError(t(.read_error), err);
                pb.CloseApp();
                return 0;
            };
            pushScreen(.start) catch {
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

fn pushScreen(page: Page) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const title, const list = switch (page) {
        .start => .{ t(.app_title), try startRows(allocator) },
        .reading => .{ t(.reading), try readingRows(allocator) },
        .finished => .{ t(.finished), try finishedRows(allocator) },
        .unread => .{ t(.unread), try unreadRows(allocator) },
        .activity => .{ t(.activity), try activityRows(allocator) },
        .library => .{ t(.library), try libraryRows(allocator) },
        .book => |index| .{ try z(allocator, books[index].title), try bookRows(allocator, books[index]) },
        .year => |year| .{ try i18n.alloc(allocator, .year_title, .{year}), try yearRows(allocator, year) },
    };
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
            const page = switch (opens) {
                .page => |page| page,
                .update => {
                    update.checkForUpdate(update_policy);
                    return 1;
                },
                .language => {
                    changeLanguage();
                    return 1;
                },
                .goal => {
                    openGoalKeyboard();
                    return 1;
                },
            };
            pushScreen(page) catch |err| {
                showError(t(.open_error), err);
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
        // A chart takes the right part of the second line
        const detail_width = if (row.chart == .none) text_width else @divTrunc(text_width * 2, 5);
        _ = pb.DrawTextRect(x + padding, y + padding + line_height, detail_width, line_height, row.detail.ptr, flags);
        const chart_x = x + padding + detail_width + padding;
        paintChart(row.chart, chart_x, y + padding + line_height, x + padding + text_width - chart_x, line_height);
    }
    pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
    if (selected and !row.heading) pb.DrawSelection(x, y, width, item_height, pb.BLACK);
}

fn paintChart(chart: Chart, x: c_int, y: c_int, width: c_int, height: c_int) void {
    switch (chart) {
        .none => {},
        .bar => |bar| {
            const h = @divTrunc(height, 2);
            const top = y + @divTrunc(height - h, 2);
            pb.DrawRect(x, top, width, h, pb.LGRAY);
            if (bar.max == 0 or bar.value == 0) return;
            const filled: c_int = @intCast(@max(1, @as(usize, @intCast(width)) * @min(bar.value, bar.max) / bar.max));
            pb.FillArea(x, top, filled, h, pb.DGRAY);
        },
        .days => |mask| {
            // The oldest day on the left, today on the right
            const cell = @divTrunc(width, days_shown);
            const size = @min(cell - 2, @divTrunc(height * 2, 3));
            if (size <= 0) return;
            const top = y + @divTrunc(height - size, 2);
            for (0..days_shown) |i| {
                const ago: u5 = @intCast(days_shown - 1 - i);
                const left = x + @as(c_int, @intCast(i)) * cell;
                if (mask & (@as(u32, 1) << ago) != 0) {
                    pb.FillArea(left, top, size, size, pb.BLACK);
                } else {
                    pb.DrawRect(left, top, size, size, pb.LGRAY);
                }
            }
        },
    }
}

/// Days of the reading chart of the activity
const days_shown = 30;

fn z(allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    return allocator.dupeSentinel(u8, text, 0);
}

/// "41 %"
fn percent(buf: []u8, permille: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d} %", .{permille / 10}) catch "";
}

/// The rows of the start screen; the last one sets the language
fn startRowCount() c_int {
    return @intCast(screens.items[0].rows.len);
}

fn startRows(allocator: std.mem.Allocator) ![]const Row {
    const summary = stats.summarize(books);
    var rows: std.ArrayList(Row) = .empty;
    var count_buf: [48]u8 = undefined;
    var other_buf: [48]u8 = undefined;

    const reading = try stats.shelf(allocator, books, .reading);
    var ago_buf: [32]u8 = undefined;
    try rows.append(allocator, .{
        .title = t(.reading),
        .detail = if (reading.len > 0)
            try i18n.alloc(allocator, .reading_detail, .{ i18n.count(&count_buf, reading.len, .book), reading[0].title, lastRead(&ago_buf, reading[0]) })
        else
            t(.no_reading),
        .opens = .{ .page = .reading },
    });

    const finished = try stats.finishedPerMonth(allocator, books, utc_offset);
    const this_month: usize = if (finished.len > 0 and finished[0].month == dates.monthOf(today)) finished[0].count else 0;
    try rows.append(allocator, .{
        .title = t(.finished),
        .detail = try i18n.alloc(allocator, .finished_detail, .{ i18n.count(&count_buf, summary.finished, .book), this_month }),
        .opens = .{ .page = .finished },
    });

    const year = dates.dateOf(today).year;
    const this_year = try stats.yearSummary(allocator, books, year, utc_offset);
    var goal_buf: [64]u8 = undefined;
    var pace_buf: [48]u8 = undefined;
    try rows.append(allocator, .{
        .title = try z(allocator, i18n.fmt(&goal_buf, .goal, .{year})),
        .detail = if (goal > 0)
            try i18n.alloc(allocator, .goal_detail, .{ this_year.finished, goal, goalStatus(&pace_buf, this_year.finished) })
        else
            t(.goal_none),
        .opens = .goal,
        .chart = if (goal > 0) .{ .bar = .{ .value = this_year.finished, .max = goal } } else .none,
    });

    const reading_days = try journal.readingDaysIn(allocator, records, year, utc_offset);
    var days_buf: [48]u8 = undefined;
    try rows.append(allocator, .{
        .title = try i18n.alloc(allocator, .year_title, .{year}),
        .detail = try i18n.alloc(allocator, .year_detail, .{ i18n.count(&count_buf, this_year.finished, .book_finished), i18n.count(&days_buf, reading_days, .day) }),
        .opens = .{ .page = .{ .year = year } },
    });

    try rows.append(allocator, .{
        .title = t(.unread),
        .detail = try z(allocator, i18n.count(&count_buf, summary.unread, .book)),
        .opens = .{ .page = .unread },
    });

    const activity = try journal.activity(allocator, records, today, utc_offset);
    try rows.append(allocator, .{
        .title = t(.activity),
        .detail = if (activity.days > 0)
            try i18n.alloc(allocator, .activity_detail, .{ i18n.count(&count_buf, activity.days_last_30, .day), activity.streak })
        else
            t(.activity_empty),
        .opens = .{ .page = .activity },
    });

    const authors = try stats.authors(allocator, books);
    try rows.append(allocator, .{
        .title = t(.library),
        .detail = try i18n.alloc(allocator, .library_detail, .{ i18n.count(&count_buf, summary.books, .book), i18n.count(&other_buf, authors.len, .author) }),
        .opens = .{ .page = .library },
    });

    if (update_policy != .off) {
        var buf: [128]u8 = undefined;
        try rows.append(allocator, .{
            .title = t(.check_updates),
            .detail = try z(allocator, update.describeInstalled(&buf)),
            .opens = .update,
        });
    }

    var language_buf: [96]u8 = undefined;
    const chosen = switch (language) {
        .auto => t(.language_auto),
        .fr => t(.language_fr),
        .en => t(.language_en),
    };
    try rows.append(allocator, .{
        .title = try z(allocator, i18n.fmt(&language_buf, .language, .{chosen})),
        .detail = t(.language_change),
        .opens = .language,
    });
    return rows.toOwnedSlice(allocator);
}

/// "2 ahead", "on track", "goal reached"
fn goalStatus(buf: []u8, finished: usize) []const u8 {
    if (finished >= goal) return t(.goal_reached);
    const pace = stats.goalPace(finished, goal, today);
    if (pace.ahead > 0) return i18n.fmt(buf, .goal_ahead, .{pace.ahead});
    if (pace.ahead < 0) return i18n.fmt(buf, .goal_behind, .{-pace.ahead});
    return t(.goal_on_track);
}

/// Where `book` is in `books`, for opening its sheet
fn bookPage(book: library.Book) ?Action {
    for (books, 0..) |other, i| {
        if (other.id == book.id) return .{ .page = .{ .book = i } };
    }
    return null;
}

fn bookRows(allocator: std.mem.Allocator, book: library.Book) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var day_buf: [32]u8 = undefined;
    var other_buf: [32]u8 = undefined;
    var count_buf: [48]u8 = undefined;

    if (book.author.len > 0) try rows.append(allocator, .{ .title = try z(allocator, book.author), .heading = true });

    const progress = book.progress orelse library.Progress{};
    const read = progress.permille();
    var percent_buf: [8]u8 = undefined;
    var pages_buf: [64]u8 = undefined;
    const pages = if (progress.pages > 0) i18n.fmt(&pages_buf, .pages, .{ progress.page, progress.pages })[0..] else "";
    try rows.append(allocator, .{
        .title = t(.book_progress),
        .detail = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ percent(&percent_buf, read), pages }, 0),
        .chart = .{ .bar = .{ .value = read, .max = 1000 } },
    });

    const pace = journal.pace(records, book.id, today, utc_offset);
    const finished_on = stats.finishedDay(book, utc_offset);
    if (finished_on) |day| {
        // The time it took is known when the journal saw the book from about its start
        const started = if (pace) |p| (if (p.since_permille <= 50 and p.since <= day) p.since else null) else null;
        try rows.append(allocator, .{
            .title = t(.book_finished_on),
            .detail = if (started) |since|
                try i18n.alloc(allocator, .book_read_in, .{ dates.formatDay(&day_buf, day, today), i18n.count(&count_buf, @intCast(day - since + 1), .day) })
            else
                try z(allocator, dates.formatDay(&day_buf, day, today)),
        });
    }

    if (pace) |p| {
        try rows.append(allocator, .{
            .title = t(.book_since),
            .detail = try i18n.alloc(allocator, .book_since_detail, .{ dates.formatDay(&day_buf, p.since, today), percent(&percent_buf, p.since_permille) }),
        });
        if (finished_on == null) {
            var rate_buf: [32]u8 = undefined;
            const rate: ?[]const u8 = if (p.per_day <= 0)
                null
            else if (progress.pages > 0)
                i18n.count(&rate_buf, @intFromFloat(@round(p.per_day * @as(f32, @floatFromInt(progress.pages)) / 1000)), .page)
            else
                std.fmt.bufPrint(&rate_buf, "{d:.1} %", .{p.per_day / 10}) catch null;
            try rows.append(allocator, .{
                .title = t(.book_pace),
                .detail = if (rate) |r| try i18n.alloc(allocator, .book_pace_detail, .{r}) else t(.book_pace_none),
            });
            try rows.append(allocator, .{
                .title = t(.book_finish),
                .detail = if (p.finish) |finish|
                    try i18n.alloc(allocator, .book_finish_detail, .{ dates.formatDay(&other_buf, finish, today), i18n.count(&count_buf, @intCast(@max(0, finish - today)), .day) })
                else
                    t(.book_finish_none),
            });
        }
    }

    var ago_buf: [32]u8 = undefined;
    const last = lastRead(&ago_buf, book);
    if (last.len > 0) try rows.append(allocator, .{ .title = t(.book_last), .detail = try z(allocator, last) });
    if (book.added > 0) try rows.append(allocator, .{
        .title = t(.book_added),
        .detail = try z(allocator, dates.formatDay(&day_buf, dates.dayOf(book.added, utc_offset), today)),
    });
    return rows.toOwnedSlice(allocator);
}

fn yearRows(allocator: std.mem.Allocator, year: i32) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const summary = try stats.yearSummary(allocator, books, year, utc_offset);
    var count_buf: [48]u8 = undefined;
    var month_buf: [16]u8 = undefined;
    const this_year = year == dates.dateOf(today).year;

    try rows.append(allocator, .{
        .title = t(.year_finished),
        .detail = if (this_year and goal > 0)
            try i18n.alloc(allocator, .year_finished_goal, .{ summary.finished, goal })
        else
            try z(allocator, i18n.count(&count_buf, summary.finished, .book)),
        .chart = if (this_year and goal > 0) .{ .bar = .{ .value = summary.finished, .max = goal } } else .none,
    });
    if (summary.pages > 0) try rows.append(allocator, .{
        .title = t(.year_pages),
        .detail = try i18n.alloc(allocator, .year_pages_detail, .{summary.pages}),
    });
    const reading_days = try journal.readingDaysIn(allocator, records, year, utc_offset);
    if (reading_days > 0) try rows.append(allocator, .{
        .title = t(.year_days),
        .detail = try z(allocator, i18n.count(&count_buf, reading_days, .day)),
    });
    if (summary.longest) |book| try rows.append(allocator, .{
        .title = t(.year_longest),
        .detail = try i18n.alloc(allocator, .year_longest_detail, .{ book.title, book.progress.?.pages }),
        .opens = bookPage(book),
    });
    if (summary.top_author) |author| try rows.append(allocator, .{
        .title = t(.year_author),
        .detail = try std.fmt.allocPrintSentinel(allocator, "{s} · {s}", .{ author.name, i18n.count(&count_buf, author.count, .book) }, 0),
    });

    var best: usize = 0;
    for (summary.per_month, 0..) |count, i| {
        if (count > summary.per_month[best]) best = i;
    }
    const month_base = year * 12;
    if (summary.finished > 0) {
        try rows.append(allocator, .{
            .title = t(.year_best_month),
            .detail = try std.fmt.allocPrintSentinel(allocator, "{s} · {s}", .{
                dates.formatMonth(&month_buf, month_base + @as(i32, @intCast(best))),
                i18n.count(&count_buf, summary.per_month[best], .book_finished),
            }, 0),
        });
        // The months up to now, as bars
        const last_month: usize = if (this_year) dates.dateOf(today).month else 12;
        try rows.append(allocator, .{ .title = t(.year_per_month), .heading = true });
        for (0..last_month) |i| try rows.append(allocator, .{
            .title = try z(allocator, dates.formatMonth(&month_buf, month_base + @as(i32, @intCast(i)))),
            .detail = try z(allocator, i18n.count(&count_buf, summary.per_month[i], .book)),
            .chart = .{ .bar = .{ .value = summary.per_month[i], .max = summary.per_month[best] } },
        });
    }

    const years = try stats.finishedYears(allocator, books, utc_offset);
    var others: usize = 0;
    for (years) |other| {
        if (other == year) continue;
        if (others == 0) try rows.append(allocator, .{ .title = t(.other_years), .heading = true });
        others += 1;
        try rows.append(allocator, .{
            .title = try i18n.alloc(allocator, .year_title, .{other}),
            .opens = .{ .page = .{ .year = other } },
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
        var pages_buf: [64]u8 = undefined;
        const pages = if (progress.pages > 0) i18n.fmt(&pages_buf, .pages, .{ progress.page, progress.pages })[0..] else "";
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = try i18n.alloc(allocator, .reading_row, .{ percent(&percent_buf, progress.permille()), lastRead(&ago_buf, book), pages }),
            .opens = bookPage(book),
        };
    }
    return rows;
}

fn finishedRows(allocator: std.mem.Allocator) ![]const Row {
    const list = try stats.shelf(allocator, books, .finished);
    const rows = try allocator.alloc(Row, list.len);
    for (list, rows) |book, *row| {
        const progress = book.progress.?;
        var day_buf: [32]u8 = undefined;
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = if (progress.completed_at > 0)
                try i18n.alloc(allocator, .finished_row, .{ dates.formatDay(&day_buf, dates.dayOf(progress.completed_at, utc_offset), today), book.author })
            else
                try i18n.alloc(allocator, .finished_row_unknown, .{book.author}),
            .opens = bookPage(book),
        };
    }
    return rows;
}

fn unreadRows(allocator: std.mem.Allocator) ![]const Row {
    const list = try stats.shelf(allocator, books, .unread);
    const rows = try allocator.alloc(Row, list.len);
    for (list, rows) |book, *row| {
        var day_buf: [32]u8 = undefined;
        const added = if (book.added > 0) dates.formatDay(&day_buf, dates.dayOf(book.added, utc_offset), today) else "?";
        row.* = .{
            .title = try z(allocator, book.title),
            .detail = try i18n.alloc(allocator, .unread_row, .{ book.author, added, if (book.on_device) "" else t(.in_cloud) }),
        };
    }
    return rows;
}

fn activityRows(allocator: std.mem.Allocator) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const activity = try journal.activity(allocator, records, today, utc_offset);
    var day_buf: [32]u8 = undefined;
    var count_buf: [48]u8 = undefined;

    try rows.append(allocator, .{
        .title = try i18n.alloc(allocator, .days_30, .{i18n.count(&count_buf, activity.days_last_30, .day)}),
        .detail = try i18n.alloc(allocator, .streak, .{i18n.count(&count_buf, activity.streak, .day)}),
        .chart = .{ .days = journal.recentDays(records, today, utc_offset, days_shown) },
    });
    try rows.append(allocator, .{
        .title = t(.how),
        .detail = if (activity.since) |since|
            try i18n.alloc(allocator, .how_since, .{dates.formatDay(&day_buf, since, today)})
        else
            t(.how_plain),
    });

    const list = try journal.steps(allocator, records);
    if (list.len > 0) try rows.append(allocator, .{ .title = t(.recent), .heading = true });
    for (list) |step| {
        var from_buf: [8]u8 = undefined;
        var to_buf: [8]u8 = undefined;
        const day = dates.formatDay(&day_buf, dates.dayOf(step.record.time, utc_offset), today);
        const to = percent(&to_buf, step.record.permille);
        try rows.append(allocator, .{
            .title = try z(allocator, step.record.title),
            .detail = if (step.record.permille == 1000)
                try i18n.alloc(allocator, .step_finished, .{day})
            else if (step.from) |from|
                try i18n.alloc(allocator, .step_from, .{ day, percent(&from_buf, from), to })
            else
                try i18n.alloc(allocator, .step_at, .{ day, to }),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn maxCount(months: []const stats.MonthCount) usize {
    var max: usize = 0;
    for (months) |entry| max = @max(max, entry.count);
    return max;
}

fn libraryRows(allocator: std.mem.Allocator) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    const summary = stats.summarize(books);
    var month_buf: [16]u8 = undefined;
    var count_buf: [48]u8 = undefined;

    try rows.append(allocator, .{
        .title = try z(allocator, i18n.count(&count_buf, summary.books, .book)),
        .detail = try i18n.alloc(allocator, .on_reader, .{ summary.on_device, summary.books - summary.on_device }),
    });

    const finished = try stats.finishedPerMonth(allocator, books, utc_offset);
    if (finished.len > 0) try rows.append(allocator, .{ .title = t(.finished_per_month), .heading = true });
    for (finished) |entry| try rows.append(allocator, .{
        .title = try z(allocator, dates.formatMonth(&month_buf, entry.month)),
        .detail = try z(allocator, i18n.count(&count_buf, entry.count, .book_finished)),
        .chart = .{ .bar = .{ .value = entry.count, .max = maxCount(finished) } },
    });

    const authors = try stats.authors(allocator, books);
    if (authors.len > 0) try rows.append(allocator, .{ .title = t(.authors), .heading = true });
    for (authors[0..@min(authors.len, 20)]) |entry| try rows.append(allocator, .{
        .title = try z(allocator, entry.name),
        .detail = try z(allocator, i18n.count(&count_buf, entry.count, .book)),
    });

    const series = try stats.series(allocator, books);
    if (series.len > 0) try rows.append(allocator, .{ .title = t(.series), .heading = true });
    for (series) |entry| try rows.append(allocator, .{
        .title = try z(allocator, entry.name),
        .detail = try z(allocator, i18n.count(&count_buf, entry.count, .book)),
    });

    const added = try stats.addedPerMonth(allocator, books, utc_offset);
    if (added.len > 0) try rows.append(allocator, .{ .title = t(.added_per_month), .heading = true });
    for (added) |entry| try rows.append(allocator, .{
        .title = try z(allocator, dates.formatMonth(&month_buf, entry.month)),
        .detail = try z(allocator, i18n.count(&count_buf, entry.count, .book_added)),
        .chart = .{ .bar = .{ .value = entry.count, .max = maxCount(added) } },
    });

    const formats = try stats.formats(allocator, books);
    if (formats.len > 0) try rows.append(allocator, .{ .title = t(.formats), .heading = true });
    for (formats) |entry| {
        var upper: [16]u8 = undefined;
        const name = entry.name[0..@min(entry.name.len, upper.len)];
        try rows.append(allocator, .{
            .title = try z(allocator, std.ascii.upperString(upper[0..name.len], name)),
            .detail = try z(allocator, i18n.count(&count_buf, entry.count, .book)),
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn main() void {
    gpa = std.heap.c_allocator;
    data_arena = .init(gpa);
    pb.InkViewMain(mainHandler);
}
