const std = @import("std");
const markz = @import("markz");
const clauses = @import("clauses.zig");
const reflow = @import("reflow.zig");

test {
    _ = clauses;
    _ = reflow;
}

const max_file_size = std.Io.Limit.limited(16 * 1024 * 1024);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip argv[0]

    var fix = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            fix = true;
        } else {
            try paths.append(gpa, arg);
        }
    }

    if (paths.items.len == 0) {
        std.debug.print("usage: semantic-clause-break [--fix] <file>...\n", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    var any_errors = false;
    var any_changed = false;

    for (paths.items) |path| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const source = cwd.readFileAlloc(io, path, arena, max_file_size) catch |err| {
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
