//! The texts of the app, in English and French.

const std = @import("std");

pub const Lang = enum {
    en,
    fr,

    /// The language for a reader language code ("fr", "fr_FR", "en", ...)
    pub fn fromCode(code: []const u8) Lang {
        return if (std.ascii.startsWithIgnoreCase(code, "fr")) .fr else .en;
    }
};

/// What the user picked: follow the reader, or one of the languages
pub const Choice = enum {
    auto,
    en,
    fr,

    pub fn parse(text: []const u8) Choice {
        return std.meta.stringToEnum(Choice, std.mem.trim(u8, text, " \t\r\n")) orelse .auto;
    }

    pub fn next(choice: Choice) Choice {
        return switch (choice) {
            .auto => .fr,
            .fr => .en,
            .en => .auto,
        };
    }

    pub fn resolve(choice: Choice, reader_code: []const u8) Lang {
        return switch (choice) {
            .auto => Lang.fromCode(reader_code),
            .en => .en,
            .fr => .fr,
        };
    }
};

/// The language texts are given in
pub var lang: Lang = .en;

/// Every text, first in English, then in French. Texts with {} take arguments, see `fmt`.
const texts = .{
    .app_title = .{ "Reading Stats", "Statistiques de lecture" },
    .read_error = .{ "Could not read the library", "Impossible de lire la bibliothèque" },
    .open_error = .{ "Could not open the list", "Impossible d'ouvrir la liste" },
    .reading = .{ "Reading", "En cours" },
    .reading_detail = .{ "{s} · last: {s}, {s}", "{s} · dernier : {s}, {s}" },
    .no_reading = .{ "No book being read", "Aucun livre en cours" },
    .finished = .{ "Finished", "Terminés" },
    .finished_detail = .{ "{s} · {d} this month", "{s} · {d} ce mois-ci" },
    .unread = .{ "Not started", "Pas commencés" },
    .activity = .{ "Activity", "Activité" },
    .activity_detail = .{ "{s} of reading in the last 30 days · streak: {d}", "{s} de lecture sur les 30 derniers jours · série : {d}" },
    .activity_empty = .{ "Recorded from now on, each time you open this app", "Notée à partir de maintenant, à chaque ouverture de l'app" },
    .library = .{ "Library", "Bibliothèque" },
    .library_detail = .{ "{s} · {s}", "{s} · {s}" },
    .reading_row = .{ "{s} · read {s}{s}", "{s} · lu {s}{s}" },
    .pages = .{ " · page {d} of {d}", " · page {d} sur {d}" },
    .finished_row = .{ "Finished {s} · {s}", "Terminé le {s} · {s}" },
    .finished_row_unknown = .{ "Finished, date unknown · {s}", "Terminé, date inconnue · {s}" },
    .unread_row = .{ "{s} · added {s}{s}", "{s} · ajouté le {s}{s}" },
    .in_cloud = .{ " · in the cloud", " · dans le cloud" },
    .days_30 = .{ "{s} of reading in the last 30 days", "{s} de lecture sur les 30 derniers jours" },
    .streak = .{ "Current streak: {s}", "Série en cours : {s}" },
    .how = .{ "How this works", "Comment ça marche" },
    .how_since = .{ "Progress noted each time this app opens, since {s}", "Progression notée à chaque ouverture de l'app, depuis le {s}" },
    .how_plain = .{ "Progress is noted each time this app opens", "La progression est notée à chaque ouverture de l'app" },
    .recent = .{ "Recent progress", "Progression récente" },
    .step_finished = .{ "{s} · finished", "{s} · terminé" },
    .step_from = .{ "{s} · {s} → {s}", "{s} · {s} → {s}" },
    .step_at = .{ "{s} · at {s}", "{s} · à {s}" },
    .on_reader = .{ "{d} on the reader, {d} only in the cloud", "{d} sur la liseuse, {d} seulement dans le cloud" },
    .finished_per_month = .{ "Finished per month", "Terminés par mois" },
    .authors = .{ "Authors", "Auteurs" },
    .series = .{ "Series", "Séries" },
    .added_per_month = .{ "Added per month", "Ajoutés par mois" },
    .formats = .{ "Formats", "Formats" },
    .goal = .{ "Goal {d}", "Objectif {d}" },
    .goal_detail = .{ "{d} of {d} books finished · {s}", "{d} livres terminés sur {d} · {s}" },
    .goal_ahead = .{ "{d} ahead", "{d} d'avance" },
    .goal_behind = .{ "{d} behind", "{d} de retard" },
    .goal_on_track = .{ "on track", "dans les temps" },
    .goal_reached = .{ "goal reached", "objectif atteint" },
    .goal_none = .{ "Tap to set a number of books to finish this year", "Touchez pour fixer un nombre de livres à finir cette année" },
    .goal_keyboard = .{ "Books to finish in {d} (0: no goal)", "Livres à finir en {d} (0 : aucun objectif)" },
    .year_title = .{ "{d} in review", "Bilan {d}" },
    .year_detail = .{ "{s} · {s} of reading", "{s} · {s} de lecture" },
    .year_finished = .{ "Books finished", "Livres terminés" },
    .year_finished_goal = .{ "{d} · goal: {d}", "{d} · objectif : {d}" },
    .year_pages = .{ "Pages read", "Pages lues" },
    .year_pages_detail = .{ "{d} pages in the books finished", "{d} pages dans les livres terminés" },
    .year_days = .{ "Reading days", "Jours de lecture" },
    .year_longest = .{ "Longest book", "Livre le plus long" },
    .year_longest_detail = .{ "{s} · {d} pages", "{s} · {d} pages" },
    .year_author = .{ "Most read author", "Auteur le plus lu" },
    .year_best_month = .{ "Best month", "Meilleur mois" },
    .year_per_month = .{ "Finished per month", "Terminés par mois" },
    .other_years = .{ "Other years", "Autres années" },
    .book_progress = .{ "Progress", "Progression" },
    .book_since = .{ "Followed since", "Suivi depuis" },
    .book_since_detail = .{ "{s}, at {s}", "le {s}, à {s}" },
    .book_pace = .{ "Pace", "Rythme" },
    .book_pace_detail = .{ "{s} a day over the last month", "{s} par jour sur le dernier mois" },
    .book_pace_none = .{ "Not enough reading recorded yet", "Pas encore assez de lecture notée" },
    .book_finish = .{ "Estimated end", "Fin estimée" },
    .book_finish_detail = .{ "around {s} (in {s})", "vers le {s} (dans {s})" },
    .book_finish_none = .{ "Unknown while the book does not move", "Inconnue tant que le livre n'avance pas" },
    .book_finished_on = .{ "Finished", "Terminé" },
    .book_read_in = .{ "{s} · read in {s}", "le {s} · lu en {s}" },
    .book_last = .{ "Last read", "Dernière lecture" },
    .book_added = .{ "Added", "Ajouté" },
    .language = .{ "Language: {s}", "Langue : {s}" },
    .language_auto = .{ "same as the reader", "celle de la liseuse" },
    .language_change = .{ "English or French", "Français ou anglais" },
    .language_title = .{ "Language", "Langue" },
    .current_choice = .{ "Current choice", "Choix actuel" },
    .language_en = .{ "English", "English" },
    .language_fr = .{ "Français", "Français" },
};

/// Words that change with a number: English singular and plural, then French ones
const nouns = .{
    .book = .{ "book", "books", "livre", "livres" },
    .author = .{ "author", "authors", "auteur", "auteurs" },
    .day = .{ "day", "days", "jour", "jours" },
    .book_finished = .{ "book finished", "books finished", "livre terminé", "livres terminés" },
    .book_added = .{ "book added", "books added", "livre ajouté", "livres ajoutés" },
    .page = .{ "page", "pages", "page", "pages" },
};

pub const Key = std.meta.FieldEnum(@TypeOf(texts));
pub const Noun = std.meta.FieldEnum(@TypeOf(nouns));

/// A text without arguments
pub fn t(comptime key: Key) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    return switch (lang) {
        .en => pair[0],
        .fr => pair[1],
    };
}

/// A text with arguments, written into `buf`
pub fn fmt(buf: []u8, comptime key: Key, args: anytype) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    const text = switch (lang) {
        .en => std.fmt.bufPrintSentinel(buf, pair[0], args, 0),
        .fr => std.fmt.bufPrintSentinel(buf, pair[1], args, 0),
    };
    return text catch "…";
}

/// A text with arguments, allocated
pub fn alloc(allocator: std.mem.Allocator, comptime key: Key, args: anytype) ![:0]const u8 {
    const pair = @field(texts, @tagName(key));
    return switch (lang) {
        .en => std.fmt.allocPrintSentinel(allocator, pair[0], args, 0),
        .fr => std.fmt.allocPrintSentinel(allocator, pair[1], args, 0),
    };
}

/// "3 books", "1 livre", "0 livre": in French 0 and 1 take the singular
pub fn count(buf: []u8, n: usize, comptime noun: Noun) []const u8 {
    const words = @field(nouns, @tagName(noun));
    const word = switch (lang) {
        .en => if (n == 1) words[0] else words[1],
        .fr => if (n <= 1) words[2] else words[3],
    };
    return std.fmt.bufPrint(buf, "{d} {s}", .{ n, word }) catch "";
}

test "every text exists in both languages with the same arguments" {
    inline for (@typeInfo(@TypeOf(texts)).@"struct".field_names) |name| {
        const pair = @field(texts, name);
        try std.testing.expectEqual(2, pair.len);
        try std.testing.expectEqual(std.mem.count(u8, pair[0], "{"), std.mem.count(u8, pair[1], "{"));
    }
    inline for (@typeInfo(@TypeOf(nouns)).@"struct".field_names) |name| {
        try std.testing.expectEqual(4, @field(nouns, name).len);
    }
}

test "counts follow the rules of each language" {
    var buf: [32]u8 = undefined;
    defer lang = .en;
    lang = .en;
    try std.testing.expectEqualStrings("0 books", count(&buf, 0, .book));
    try std.testing.expectEqualStrings("1 book", count(&buf, 1, .book));
    lang = .fr;
    try std.testing.expectEqualStrings("0 livre", count(&buf, 0, .book));
    try std.testing.expectEqualStrings("1 livre terminé", count(&buf, 1, .book_finished));
    try std.testing.expectEqualStrings("3 livres ajoutés", count(&buf, 3, .book_added));
}

test "texts follow the chosen language" {
    defer lang = .en;
    lang = .fr;
    try std.testing.expectEqualStrings("Bibliothèque", t(.library));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" · page 3 sur 10", fmt(&buf, .pages, .{ 3, 10 }));
    try std.testing.expectEqual(Lang.fr, Choice.auto.resolve("fr_FR"));
}
