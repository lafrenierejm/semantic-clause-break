const std = @import("std");
const markz = @import("markz");
const clauses = @import("clauses.zig");
const reflow = @import("reflow.zig");

test {
    _ = clauses;
    _ = reflow;
    _ = @import("spec_test.zig");
}

fn expectOk(args: []const []const u8, expected: Options) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try parseArgs(arena.allocator(), args);
    const opts = switch (outcome) {
        .ok => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected.fix, opts.fix);
    try std.testing.expectEqual(expected.max_size_mib, opts.max_size_mib);
    try std.testing.expectEqual(expected.paths.len, opts.paths.len);
    for (expected.paths, opts.paths) |e, a| try std.testing.expectEqualStrings(e, a);
}

fn expectInvalid(args: []const []const u8, expected_msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try parseArgs(arena.allocator(), args);
    switch (outcome) {
        .invalid => |msg| try std.testing.expectEqualStrings(expected_msg, msg),
        else => return error.TestUnexpectedResult,
    }
}

test "parseArgs: defaults with a single path" {
    try expectOk(&.{"a.md"}, .{ .paths = &.{"a.md"} });
}

test "parseArgs: --fix and --max-size-mib" {
    try expectOk(
        &.{ "--fix", "--max-size-mib", "4", "a.md" },
        .{ .fix = true, .max_size_mib = 4, .paths = &.{"a.md"} },
    );
}

test "parseArgs: --help and -h short-circuit before paths are required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"--help"})) == .help);
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"-h"})) == .help);
}

test "parseArgs: no paths is reported separately from a bad flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseArgs(arena.allocator(), &.{})) == .missing_paths);
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"--fix"})) == .missing_paths);
}

test "parseArgs: --max-size-mib requires a value" {
    try expectInvalid(&.{"--max-size-mib"}, "--max-size-mib requires a value");
}

test "parseArgs: --max-size-mib rejects a non-numeric value" {
    try expectInvalid(&.{ "--max-size-mib", "abc" }, "--max-size-mib: invalid MiB count: abc");
}

test "parseArgs: unknown flag is rejected instead of read as a path" {
    try expectInvalid(&.{ "--fixx", "a.md" }, "unknown flag: --fixx");
}

test "parseArgs: duplicate path is deduplicated" {
    try expectOk(&.{ "a.md", "b.md", "a.md" }, .{ .paths = &.{ "a.md", "b.md" } });
}

test "parseArgs: -- ends flag parsing so a leading-dash path is accepted literally" {
    try expectOk(&.{ "--", "-weird.md" }, .{ .paths = &.{"-weird.md"} });
}

test "parseArgs: -- must have following arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseArgs(arena.allocator(), &.{"--"})) == .missing_paths);
}

test "exitCode: check mode fails only when a file has errors" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(false, false, false));
    try std.testing.expectEqual(@as(u8, 1), exitCode(false, true, false));
}

test "exitCode: fix mode fails when a file changed" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(true, false, false));
    try std.testing.expectEqual(@as(u8, 1), exitCode(true, false, true));
}

test "exitCode: fix mode still fails when a file errored, even if nothing changed" {
    try std.testing.expectEqual(@as(u8, 1), exitCode(true, true, false));
}

const default_max_size_mib: usize = 16;

const program_name = "semantic-clause-break";
const positional_usage = "<file>...";

const FlagId = enum { fix, max_size_mib, help };

const Flag = struct {
    id: FlagId,
    long: []const u8,
    short: ?[]const u8 = null,
    help: []const u8,
};

const flags = [_]Flag{
    .{ .id = .fix, .long = "--fix", .help = "Apply fixes to the given files instead of only reporting errors." },
    .{ .id = .max_size_mib, .long = "--max-size-mib", .help = std.fmt.comptimePrint("Maximum file size to read, in MiB (default: {d}).", .{default_max_size_mib}) },
    .{ .id = .help, .long = "--help", .short = "-h", .help = "Print this help message and exit." },
};

/// Find the `flags` entry whose long or short form matches `arg`, if any.
fn matchFlag(arg: []const u8) ?Flag {
    for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag.long)) return flag;
        if (flag.short) |short| {
            if (std.mem.eql(u8, arg, short)) return flag;
        }
    }
    return null;
}

fn printUsage() void {
    std.debug.print("usage: {s} [options] {s}\n\noptions:\n", .{ program_name, positional_usage });
    for (flags) |flag| {
        if (flag.short) |short| {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "{s}, {s}", .{ short, flag.long }) catch unreachable;
            std.debug.print("  {s: <16} {s}\n", .{ name, flag.help });
        } else {
            std.debug.print("  {s: <16} {s}\n", .{ flag.long, flag.help });
        }
    }
}

const Options = struct {
    fix: bool = false,
    max_size_mib: usize = default_max_size_mib,
    paths: []const []const u8 = &.{},
};

/// Result of parsing argv.
/// `invalid` carries a ready-to-print message (no trailing newline).
/// `help` and `missing_paths` are handled by printing the usage banner.
const ParseOutcome = union(enum) {
    help,
    missing_paths,
    invalid: []const u8,
    ok: Options,
};

/// Parse `args` (argv without argv[0]). Every string/slice in the result is
/// allocated from `allocator`; pass an arena so the caller doesn't need to
/// free anything piecemeal.
///
/// A `--` argument ends flag parsing: every argument after it is taken as a
/// literal path, even one starting with `-` (e.g. `-weird.md`). Before
/// `--`, an argument starting with `-` that isn't a recognized flag is
/// rejected rather than silently read as a path.
///
/// A path repeated in `args` is silently deduplicated (first occurrence
/// wins, order preserved). `--fix` reads and rewrites each path from its
/// own concurrently running task, so processing the same path twice would
/// race a read against a write to that file.
fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParseOutcome {
    var fix = false;
    var max_size_mib: usize = default_max_size_mib;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    var only_paths = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!only_paths) {
            if (std.mem.eql(u8, arg, "--")) {
                only_paths = true;
                continue;
            }
            if (matchFlag(arg)) |flag| {
                switch (flag.id) {
                    .fix => fix = true,
                    .max_size_mib => {
                        i += 1;
                        if (i >= args.len) {
                            return .{ .invalid = try std.fmt.allocPrint(allocator, "{s} requires a value", .{flag.long}) };
                        }
                        const value = args[i];
                        max_size_mib = std.fmt.parseInt(usize, value, 10) catch {
                            return .{ .invalid = try std.fmt.allocPrint(allocator, "{s}: invalid MiB count: {s}", .{ flag.long, value }) };
                        };
                    },
                    .help => return .help,
                }
                continue;
            }
            if (arg.len >= 2 and arg[0] == '-') {
                return .{ .invalid = try std.fmt.allocPrint(allocator, "unknown flag: {s}", .{arg}) };
            }
        }

        var already_seen = false;
        for (paths.items) |seen| {
            if (std.mem.eql(u8, seen, arg)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) continue;
        try paths.append(allocator, arg);
    }

    if (paths.items.len == 0) return .missing_paths;

    return .{ .ok = .{ .fix = fix, .max_size_mib = max_size_mib, .paths = try paths.toOwnedSlice(allocator) } };
}

const FileOutcome = union(enum) {
    err: anyerror,
    checked: usize,
    fixed: bool,
};

const max_tmp_name_attempts = 8;

/// Replace `path`'s contents with `data` by writing a sibling temp file and
/// renaming it over `path`, instead of truncating `path` in place. The
/// rename is atomic, so a write error or crash partway through leaves the
/// original file intact instead of truncated or corrupt; the errdefer
/// cleans up the orphaned temp file on any failure.
///
/// The temp file is created with a random name and `exclusive = true`, so
/// an unrelated file that happens to already sit at that name (e.g. a
/// leftover `foo.md.tmp` of the user's own) is never overwritten; a name
/// collision is retried with a fresh random suffix, up to
/// `max_tmp_name_attempts` times.
fn writeFileAtomic(io: std.Io, allocator: std.mem.Allocator, cwd: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var attempt: usize = 0;
    const tmp_path = while (attempt < max_tmp_name_attempts) : (attempt += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);
        const candidate = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, suffix });
        cwd.writeFile(io, .{
            .sub_path = candidate,
            .data = data,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break candidate;
    } else return error.PathAlreadyExists;

    errdefer cwd.deleteFile(io, tmp_path) catch {};
    try cwd.rename(tmp_path, cwd, path, io);
}

fn processFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: std.Io.Dir,
    path: []const u8,
    fix: bool,
    max_file_size: std.Io.Limit,
) FileOutcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = cwd.readFileAlloc(io, path, arena, max_file_size) catch |err| return .{ .err = err };
    var doc = markz.parseWith(arena, source, .{ .gfm = true }) catch |err| return .{ .err = err };
    const result = reflow.analyze(arena, &doc) catch |err| return .{ .err = err };

    if (fix) {
        if (result.insertions.len == 0) return .{ .fixed = false };
        const fixed = reflow.applyInsertions(arena, source, result.insertions) catch |err| return .{ .err = err };
        writeFileAtomic(io, arena, cwd, path, fixed) catch |err| return .{ .err = err };
        return .{ .fixed = true };
    }

    return .{ .checked = result.insertions.len };
}

/// Combine the per-file outcomes into a process exit code.
fn exitCode(fix: bool, any_errors: bool, any_changed: bool) u8 {
    if (any_errors) return 1;
    if (fix) return if (any_changed) 1 else 0;
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip argv[0]

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var raw_args: std.ArrayListUnmanaged([]const u8) = .empty;
    while (arg_iter.next()) |arg| try raw_args.append(arena, arg);

    const opts = switch (try parseArgs(arena, raw_args.items)) {
        .help => {
            printUsage();
            return 0;
        },
        .missing_paths => {
            printUsage();
            return 2;
        },
        .invalid => |msg| {
            std.debug.print("{s}\n", .{msg});
            return 2;
        },
        .ok => |o| o,
    };

    const max_file_size = std.math.mul(usize, opts.max_size_mib, 1024 * 1024) catch {
        std.debug.print("--max-size-mib: value too large: {d}\n", .{opts.max_size_mib});
        return 2;
    };

    const cwd = std.Io.Dir.cwd();
    const file_size_limit = std.Io.Limit.limited(max_file_size);

    const futures = try gpa.alloc(std.Io.Future(FileOutcome), opts.paths.len);
    defer gpa.free(futures);

    // Each file is read, parsed, and analyzed independently, so let the Io
    // implementation overlap their I/O instead of processing sequentially.
    for (opts.paths, futures) |path, *future| {
        future.* = std.Io.async(io, processFile, .{ io, gpa, cwd, path, opts.fix, file_size_limit });
    }

    var any_errors = false;
    var any_changed = false;
    for (opts.paths, futures) |path, *future| {
        switch (future.await(io)) {
            .err => |err| {
                std.debug.print("{s}: {t}\n", .{ path, err });
                any_errors = true;
            },
            .checked => |error_count| {
                std.debug.print("{s}: {d} error(s)\n", .{ path, error_count });
                if (error_count > 0) any_errors = true;
            },
            .fixed => |changed| {
                if (changed) any_changed = true;
            },
        }
    }

    return exitCode(opts.fix, any_errors, any_changed);
}
