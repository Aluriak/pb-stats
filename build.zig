const std = @import("std");

/// The title of the app: the name on the PocketBook applications menu, the header of the
/// start screen and the name in the task switcher.
const app_name = "Reading Stats";

const version = @import("build.zig.zon").version;

/// PocketBook's hardware families run the same firmware but differ in how their system
/// libraries pass floating point values, and a binary only loads on the matching kind.
const Platform = enum {
    /// Allwinner B288/B300 readers (Era, Verse, Vivlio Light HD Color, ...): soft-float
    allwinner,
    /// Rockchip RK3566 readers (Verta, InkPad One, PocketBook Q): hard-float
    rk3566,
};

/// SQLite is built into the app: the reader's own copy is not part of the SDK.
/// Only what reading a database needs is kept.
const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=0",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DQS=0",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK",
};

pub fn build(b: *std.Build) void {
    const platform = b.option(Platform, "platform", "Reader hardware to build for (default: allwinner)") orelse .allwinner;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = switch (platform) {
            .allwinner => .gnueabi,
            .rk3566 => .gnueabihf,
        },
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
        .os_version_min = .{ .semver = .{ .major = 3, .minor = 10, .patch = 0 } },
        // Zig's start code calls `getauxval`, which glibc has since 2.16
        .glibc_version = .{ .major = 2, .minor = 16, .patch = 0 },
    });
    const optimize = b.standardOptimizeOption(.{});

    const inkview = b.addTranslateC(.{
        .root_source_file = b.path("include/inkview.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inkview.addIncludePath(b.path("include"));

    const exe = b.addExecutable(.{
        .name = app_name ++ ".app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const options = b.addOptions();
    options.addOption([:0]const u8, "app_name", app_name);
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "platform", @tagName(platform));
    // Where the build comes from
    options.addOption([]const u8, "commit", b.option([]const u8, "commit", "Git commit the build is made from") orelse "dev");
    options.addOption([]const u8, "channel", b.option([]const u8, "channel", "nightly, release or dev (default)") orelse "dev");
    exe.root_module.addOptions("build_options", options);

    exe.root_module.addImport("c", inkview.createModule());
    addSqlite(b, exe.root_module, target);
    exe.root_module.addLibraryPath(b.path("lib"));
    exe.root_module.linkSystemLibrary("inkview", .{});

    b.installArtifact(exe);

    // `zig build test` runs the unit tests on the build machine, for the files that need
    // nothing from the reader. SQLite is built for the build machine for them.
    const test_step = b.step("test", "Run the unit tests");
    for ([_][]const u8{ "src/library.zig", "src/dates.zig", "src/stats.zig", "src/journal.zig", "src/i18n.zig" }) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = b.graph.host,
                .link_libc = true,
            }),
        });
        addSqlite(b, tests.root_module, b.graph.host);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// Compiles SQLite into `module` and makes its header importable as "sqlite"
fn addSqlite(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &sqlite_flags });

    const header = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    module.addImport("sqlite", header.createModule());
}
