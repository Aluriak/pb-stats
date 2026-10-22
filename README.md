# Reading Stats

Statistics about your reading, on PocketBook e-readers (and Vivlio, which are PocketBooks).

The reader keeps track of every book's progress but shows no statistics. Reading Stats reads
the reader's library and shows:

* **Reading:** the books you are reading, how far you are and when you last read them.
  Each book opens on its sheet: progress, since when the journal follows it, your pace over
  the last month (in pages a day) and when you would finish it at that pace.
* **Finished:** the books you finished, with the date, and how many this month. Their sheet
  says how many days you took, when the journal saw the book from its start.
* **Goal:** a number of books to finish this year, with how far you are and whether you are
  ahead of a steady pace. Touch it to set it (0 removes it); it is kept as `goal=` in
  `system/config/reading-stats.cfg`.
* **Year in review:** books and pages finished, reading days, the longest book, the most read
  author, the best month, the books finished per month, and the years before.
* **Not started:** the books in your library you never opened.
* **Activity:** reading days in the last 30 days, drawn as a row of squares, your current
  streak, and the progress of each book over time.
* **Library:** books on the reader and in the cloud, books finished and added per month as
  bars, authors, series and formats.

The manuals that come with the reader are left out.

## Install

1. Download the archive for your reader from the
   [nightly release](https://github.com/Aluriak/pb-stats/releases/tag/nightly):
   `reading-stats-allwinner.zip` for most readers (Era, Verse, InkPad 4, Vivlio Light HD Color…),
   `reading-stats-rk3566.zip` for Verta, InkPad One and PocketBook Q.
2. Unzip it and copy the `.app` file into the `applications` folder of the reader,
   or install it with the [App Manager](https://github.com/Aluriak/pb-apps).
3. Open it from the applications list.

## Updates

Install and update the app with the [App Manager](https://github.com/Aluriak/pb-apps), which
follows the stable releases of this repository, or its nightly builds if you choose so.

## Language

The app speaks English or French. By default it follows the reader's language; the last row of
the start screen opens a page to choose the reader's language, French or English. The choice is kept
in `system/config/reading-stats.cfg` as `language=auto`, `fr` or `en`.

PocketBook ends its settings files with a checksum line (`#1234abcd`) and ignores a file whose
checksum does not match. After editing the file by hand, add or fix that line with
`fix-config-checksum.py` from
[pb-opds-connector](https://github.com/Aluriak/pb-opds-connector/blob/main/scripts/fix-config-checksum.py).

## How it works

The library of the reader lives in a SQLite database,
`system/explorer-3/explorer-3.db`. The app only reads it, it never changes it. For each book it
holds the current page, whether the book is finished and when, and when it was last opened. It
keeps **no history** and **no reading time**.

So the app keeps its own journal, `system/config/reading-stats-journal.tsv`: each time the app
opens, it writes down every book whose progress changed, with the time the reader last moved in
it. The activity screen is built from that journal. The more often you open the app, the more
precise it gets: a book read on Monday and Tuesday with the app opened on Wednesday counts as
read on Tuesday only.

* Progress is counted in percent: page numbers change with the font size.
* Reading time cannot be shown, the reader does not record it.

**When copying the database for testing**, copy `explorer-3.db-wal` and `explorer-3.db-shm`
with it. The library writes recent changes into the `-wal` file first, so the database alone can
be days behind.

## Debugging

The `-debug` archives of the nightly release hold a build that writes a log:

1. Copy `Reading Stats.bin` and `stats-debug.app` into the `applications` folder.
2. Open "stats-debug" instead of "Reading Stats".
3. The log is written to `reading-stats-log.txt` in the `system` folder of the reader (out of the library, which takes text files for books).

## Development

Needs [Zig](https://ziglang.org) 0.17.0.

```sh
make test        # unit tests, on the build machine
make build-all   # the app for both platforms, into zig-out/<platform>/bin
```

`PB_STATS_TEST_DB=/path/to/explorer-3.db make test` also checks that a real reader's database
is read.

SQLite is built into the app: `vendor/sqlite` holds the amalgamation of SQLite 3.53.4, see
`vendor/sqlite/README.md`.

### Releases

Every push to `main` replaces the nightly release. To publish a stable release, set the new
version in `build.zig.zon` and push it to `main`: the build workflow sees that this version has
no release yet and publishes one, tagged `v<version>`.

## Licence

GPL-3.0, see [LICENSE](LICENSE). SQLite is in the public domain.
