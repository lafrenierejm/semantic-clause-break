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
    var any_errors = false;
    var any_changed = false;

    for (paths.items) |path| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const source = cwd.readFileAlloc(io, path, arena, std.Io.Limit.limited(max_file_size)) catch |err| {
            std.debug.print("{s}: {t}\n", .{ path, err });
            any_errors = true;
            continue;
        };

        var doc = try markz.parseWith(arena, source, .{ .gfm = true });
        const result = try reflow.analyze(arena, &doc);

        if (fix) {
            if (result.insertions.len > 0) {
                const fixed = try reflow.applyInsertions(arena, source, result.insertions);
                try cwd.writeFile(io, .{ .sub_path = path, .data = fixed });
                any_changed = true;
            }
        } else {
            std.debug.print("{s}: {d} error(s)\n", .{ path, result.insertions.len });
            if (result.insertions.len > 0) any_errors = true;
        }
    }

    if (fix) return if (any_changed) @as(u8, 1) else 0;
    return if (any_errors) @as(u8, 1) else 0;
}
