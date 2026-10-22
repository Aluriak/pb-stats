//! Turning the Unix timestamps of the library into days and months of the reader's clock.
//! The time zone is a fixed offset, taken once when the app starts.

const std = @import("std");
const i18n = @import("i18n.zig");

/// A day, counted from 1970-01-01 in local time
pub const Day = i32;

pub const Date = struct {
    year: i32,
    /// 1 to 12
    month: u8,
    /// 1 to 31
    day: u8,
};

/// The local day a timestamp falls on
pub fn dayOf(timestamp: i64, utc_offset: i32) Day {
    return @intCast(@divFloor(timestamp + utc_offset, std.time.s_per_day));
}

/// Year, month and day of a day number (Howard Hinnant's civil_from_days)
pub fn dateOf(day: Day) Date {
    const z: i64 = @as(i64, day) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// The day number of a date (Howard Hinnant's days_from_civil)
pub fn dayFromDate(date: Date) Day {
    const y: i64 = @as(i64, date.year) - @as(i64, if (date.month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = date.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + date.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @intCast(era * 146097 + doe - 719468);
}

/// The first day of `year`
pub fn yearStart(year: i32) Day {
    return dayFromDate(.{ .year = year, .month = 1, .day = 1 });
}

pub fn daysInYear(year: i32) i32 {
    return yearStart(year + 1) - yearStart(year);
}

/// A month as one number, for grouping: year * 12 + month - 1
pub const Month = i32;

pub fn monthOf(day: Day) Month {
    const date = dateOf(day);
    return date.year * 12 + date.month - 1;
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const month_names_fr = [_][]const u8{ "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." };

fn monthName(index: usize) []const u8 {
    return switch (i18n.lang) {
        .en => month_names[index],
        .fr => month_names_fr[index],
    };
}

/// "Oct 2026", "oct. 2026"
pub fn formatMonth(buf: []u8, month: Month) []const u8 {
    const year = @divFloor(month, 12);
    const index: usize = @intCast(@mod(month, 12));
    return std.fmt.bufPrint(buf, "{s} {d}", .{ monthName(index), year }) catch "";
}

/// "Oct 22" ("22 oct."), with the year when not that of `today`
pub fn formatDay(buf: []u8, day: Day, today: Day) []const u8 {
    const date = dateOf(day);
    const name = monthName(date.month - 1);
    const same_year = date.year == dateOf(today).year;
    const text = switch (i18n.lang) {
        .en => if (same_year)
            std.fmt.bufPrint(buf, "{s} {d}", .{ name, date.day })
        else
            std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ name, date.day, date.year }),
        .fr => if (same_year)
            std.fmt.bufPrint(buf, "{d} {s}", .{ date.day, name })
        else
            std.fmt.bufPrint(buf, "{d} {s} {d}", .{ date.day, name, date.year }),
    };
    return text catch "";
}

/// "today", "yesterday", "3 days ago", then the date ("aujourd'hui", "hier", "il y a 3 jours",
/// "le 8 oct.")
pub fn formatAgo(buf: []u8, day: Day, today: Day) []const u8 {
    const days = today - day;
    switch (i18n.lang) {
        .en => {
            if (days <= 0) return "today";
            if (days == 1) return "yesterday";
            if (days < 7) return std.fmt.bufPrint(buf, "{d} days ago", .{days}) catch "";
            return formatDay(buf, day, today);
        },
        .fr => {
            if (days <= 0) return "aujourd'hui";
            if (days == 1) return "hier";
            if (days < 7) return std.fmt.bufPrint(buf, "il y a {d} jours", .{days}) catch "";
            var day_buf: [32]u8 = undefined;
            return std.fmt.bufPrint(buf, "le {s}", .{formatDay(&day_buf, day, today)}) catch "";
        },
    }
}

test "dateOf and dayOf agree with known dates" {
    try std.testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, dateOf(0));
    // 2026-10-22 00:29 UTC
    const finished: i64 = 1792628940;
    try std.testing.expectEqual(Date{ .year = 2026, .month = 10, .day = 22 }, dateOf(dayOf(finished, 0)));
    // 2000-02-29 is a leap day
    try std.testing.expectEqual(Date{ .year = 2000, .month = 2, .day = 29 }, dateOf(11016));
}

test "dayOf moves late evening to the next day east of Greenwich" {
    // 2026-10-21 23:30 UTC is already the 22nd in Paris (UTC+2 in October)
    const late: i64 = 1792625400;
    try std.testing.expectEqual(@as(u8, 21), dateOf(dayOf(late, 0)).day);
    try std.testing.expectEqual(@as(u8, 22), dateOf(dayOf(late, 2 * 3600)).day);
}

test "dayFromDate is the inverse of dateOf" {
    for ([_]Day{ 0, 11016, 20748, -1, 365 * 30 + 7 }) |day| {
        try std.testing.expectEqual(day, dayFromDate(dateOf(day)));
    }
    try std.testing.expectEqual(@as(i32, 366), daysInYear(2028));
    try std.testing.expectEqual(@as(i32, 365), daysInYear(2026));
}

test "months group and print" {
    var buf: [16]u8 = undefined;
    const day = dayOf(1792628940, 0);
    try std.testing.expectEqualStrings("Oct 2026", formatMonth(&buf, monthOf(day)));
    try std.testing.expectEqual(monthOf(day) - 9, monthOf(dayOf(1792628940 - 280 * std.time.s_per_day, 0)));
}

test "formatAgo speaks of recent days, then gives the date" {
    var buf: [24]u8 = undefined;
    const today = dayOf(1792628940, 0);
    try std.testing.expectEqualStrings("today", formatAgo(&buf, today, today));
    try std.testing.expectEqualStrings("yesterday", formatAgo(&buf, today - 1, today));
    try std.testing.expectEqualStrings("3 days ago", formatAgo(&buf, today - 3, today));
    try std.testing.expectEqualStrings("Oct 8", formatAgo(&buf, today - 14, today));
    try std.testing.expectEqualStrings("Oct 22, 2025", formatAgo(&buf, today - 365, today));
}

test "dates in French" {
    i18n.lang = .fr;
    defer i18n.lang = .en;
    var buf: [32]u8 = undefined;
    const today = dayOf(1792628940, 0);
    try std.testing.expectEqualStrings("oct. 2026", formatMonth(&buf, monthOf(today)));
    try std.testing.expectEqualStrings("hier", formatAgo(&buf, today - 1, today));
    try std.testing.expectEqualStrings("il y a 3 jours", formatAgo(&buf, today - 3, today));
    try std.testing.expectEqualStrings("le 8 oct.", formatAgo(&buf, today - 14, today));
    try std.testing.expectEqualStrings("22 oct. 2025", formatDay(&buf, today - 365, today));
}
