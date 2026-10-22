# SQLite

`sqlite3.c` and `sqlite3.h` are the amalgamation of SQLite 3.53.4
(source id `2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`),
public domain.

They were taken from `deps/sqlite3/` of the npm package `better-sqlite3` 13.0.3, as sqlite.org
was not reachable when they were added. That package changes two lines of `sqlite3.c`
(`deps/patches/1208.patch`): two constants of the date functions, written as their value.

To update, replace both files with those of a newer amalgamation from
https://www.sqlite.org/download.html and update this file.
