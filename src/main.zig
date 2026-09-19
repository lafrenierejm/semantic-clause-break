const std = @import("std");
const markz = @import("markz");
const clauses = @import("clauses.zig");
const reflow = @import("reflow.zig");

test {
    _ = clauses;
    _ = reflow;
}

const default_max_size_mib: usize = 16;

const program_name = "semantic-clause-break";
const positional_usage = "<file>...";

const Flag = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    help: []const u8,
};

const flags = [_]Flag{
    .{ .long = "--fix", .help = "Apply fixes to the given files instead of only reporting errors." },
    .{ .long = "--max-size-mib", .help = std.fmt.comptimePrint("Maximum file size to read, in MiB (default: {d}).", .{default_max_size_mib}) },
    .{ .long = "--help", .short = "-h", .help = "Print this help message and exit." },
};

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

const FileOutcome = union(enum) {
    err: anyerror,
    checked: usize,
    fixed: bool,
};

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
        cwd.writeFile(io, .{ .sub_path = path, .data = fixed }) catch |err| return .{ .err = err };
        return .{ .fixed = true };
    }

    return .{ .checked = result.insertions.len };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip argv[0]

    var fix = false;
    var max_size_mib: usize = default_max_size_mib;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            fix = true;
        } else if (std.mem.eql(u8, arg, "--max-size-mib")) {
            const value = arg_iter.next() orelse {
                std.debug.print("--max-size-mib requires a value\n", .{});
                return 2;
            };
            max_size_mib = std.fmt.parseInt(usize, value, 10) catch {
                std.debug.print("--max-size-mib: invalid MiB count: {s}\n", .{value});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        } else {
            try paths.append(gpa, arg);
        }
    }

    if (paths.items.len == 0) {
        printUsage();
        return 2;
    }

    const max_file_size = std.math.mul(usize, max_size_mib, 1024 * 1024) catch {
        std.debug.print("--max-size-mib: value too large: {d}\n", .{max_size_mib});
        return 2;
    };

    const cwd = std.Io.Dir.cwd();
    const file_size_limit = std.Io.Limit.limited(max_file_size);
    var any_errors = false;
    var any_changed = false;

    const futures = try gpa.alloc(std.Io.Future(FileOutcome), paths.items.len);
    defer gpa.free(futures);

    // Each file is read, parsed, and analyzed independently, so let the Io
    // implementation overlap their I/O instead of processing sequentially.
    for (paths.items, futures) |path, *future| {
        future.* = std.Io.async(io, processFile, .{ io, gpa, cwd, path, fix, file_size_limit });
    }

    for (paths.items, futures) |path, *future| {
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

    if (fix) return if (any_changed) @as(u8, 1) else 0;
    return if (any_errors) @as(u8, 1) else 0;
}
