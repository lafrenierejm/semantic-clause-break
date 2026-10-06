//! Property tests run over every example in the GFM spec (`test/spec.txt`).
//! The spec's expected HTML is not used.
//! Tool rewrites Markdown source, so instead each example is fixed and checked for properties that must hold for any input.
//!
//! - Idempotence: fixing already-fixed output changes nothing.
//! - Semantics preserved: the fixed source renders to the same HTML as the original,
//!   treating a soft line break the same as a space.
//!
//! Few of the spec examples have two clauses on one line.
//! To get better coverage, each example is also run through mutations (see `Mutation`) that add clause boundaries next to every construct the spec covers.
//! The properties hold for any input, so a mutated example needs no expected output of its own.

const std = @import("std");
const markz = @import("markz");
const reflow = @import("reflow.zig");

const spec = @embedFile("gfm_spec");

/// Ways of deriving more inputs from a spec example. Blank lines are left
/// alone by every mutation so the example's block structure survives.
const Mutation = enum {
    /// The example exactly as the spec gives it.
    none,
    /// Add "Lead clause. " before every line
    /// A split moves the line's own leading syntax (a list marker, "#", ">", a fence, ...) to the start of a line.
    prefix_lines,
    /// Add " Tail clause." after every line, splitting before hard breaks, lazy
    /// continuations, table cells, and the ends of list and quote lines.
    suffix_lines,
    /// The first space between two alphanumerics on every line becomes
    /// ". Next ", landing splits inside emphasis, links, code spans, and
    /// entity references.
    insert_boundary,
};

/// Example/mutation pairs known to fail, each with the reason. An entry
/// that starts passing also fails the test, so this list can't go stale.
/// Entries must be in strictly increasing (number, mutation) order, which
/// is checked at compile time and also rules out duplicates. `knownFailure`
/// relies on that order to binary search.
const known_failures = [_]KnownFailure{
    .{ .number = 4, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 5, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 6, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 7, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 9, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 10, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 11, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 12, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 13, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 15, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 16, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 17, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 18, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 19, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 20, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 21, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 22, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 23, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 24, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 27, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 28, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 29, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 30, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 31, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 32, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 36, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 37, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 38, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 39, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 40, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 41, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 42, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 43, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 44, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 45, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 47, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 48, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 49, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 50, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 51, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 52, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 53, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 54, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 55, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 56, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 57, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 58, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 59, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 60, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 61, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 62, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 63, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 64, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 65, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 66, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 67, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 68, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 69, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 70, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 71, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 73, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 74, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 75, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 78, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 79, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 80, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 85, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 89, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 90, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 92, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 93, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 94, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 95, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 96, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 97, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 98, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 99, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 100, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 101, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 102, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 103, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 104, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 105, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 106, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 107, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 109, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 110, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 111, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 112, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 113, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 114, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 116, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 117, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 118, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 119, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 120, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 121, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 122, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 123, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 124, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 125, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 126, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 127, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 128, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 129, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 130, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 131, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 139, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 140, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 141, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 142, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 143, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 144, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 145, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 146, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 147, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 148, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 149, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 150, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 151, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 152, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 153, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 154, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 155, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 157, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 158, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 159, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 160, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 164, .mutation = .insert_boundary, .reason = .ref_def_label },
    .{ .number = 171, .mutation = .prefix_lines, .reason = .missed_boundary },
    .{ .number = 181, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 183, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 184, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 185, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 187, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 197, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 198, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 199, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 199, .mutation = .suffix_lines, .reason = .block_syntax },
    .{ .number = 201, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 202, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 203, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 204, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 205, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 206, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 207, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 208, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 209, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 210, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 211, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 212, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 213, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 214, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 215, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 216, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 217, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 218, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 219, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 220, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 221, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 222, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 223, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 224, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 225, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 226, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 227, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 228, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 229, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 230, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 231, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 232, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 233, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 234, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 235, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 236, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 237, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 238, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 240, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 241, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 242, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 248, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 254, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 255, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 256, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 257, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 258, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 259, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 260, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 264, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 265, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 266, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 267, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 268, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 270, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 271, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 272, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 273, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 274, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 275, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 276, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 277, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 278, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 281, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 283, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 286, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 287, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 288, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 289, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 290, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 292, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 294, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 295, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 296, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 297, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 298, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 299, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 300, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 301, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 302, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 303, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 304, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 305, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 306, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 315, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 320, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 330, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 334, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 571, .mutation = .prefix_lines, .reason = .missed_boundary },
    .{ .number = 652, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 666, .mutation = .prefix_lines, .reason = .block_syntax },
    .{ .number = 667, .mutation = .prefix_lines, .reason = .block_syntax },
};

const KnownFailure = struct { number: usize, mutation: Mutation, reason: FailureReason };

/// Identifies one input: a spec example under one mutation.
const InputKey = struct { number: usize, mutation: Mutation };

/// Orders by example number, then by mutation in declaration order.
fn compareKey(key: InputKey, entry: KnownFailure) std.math.Order {
    return switch (std.math.order(key.number, entry.number)) {
        .eq => std.math.order(@intFromEnum(key.mutation), @intFromEnum(entry.mutation)),
        else => |order| order,
    };
}

// Guarantee that `known_failures` remains ordered.
comptime {
    for (1..known_failures.len) |i| {
        const prev = known_failures[i - 1];
        const next = known_failures[i];
        const in_order = compareKey(.{ .number = prev.number, .mutation = prev.mutation }, next) == .lt;
        if (!in_order) @compileError(std.fmt.comptimePrint(
            "known_failures must be in strictly increasing (number, mutation) order: example {d} ({s}) is followed by example {d} ({s})",
            .{ prev.number, @tagName(prev.mutation), next.number, @tagName(next.mutation) },
        ));
    }
}

/// Why an entry in `known_failures` fails.
const FailureReason = enum {
    /// A split moves the next clause's leading syntax (a list marker, "#",
    /// ">", a code fence, a thematic break or setext underline, a table
    /// delimiter row, an HTML block tag) to the start of a line, where it
    /// starts a new block.
    block_syntax,
    /// The paragraph's text also appears earlier in a link reference
    /// definition's label, which isn't a node in the tree, so the split
    /// lands in the label and the paragraph itself is never split.
    ref_def_label,
    /// A second pass splits at a boundary the first pass skipped; each line
    /// splits fine in isolation. Cause not yet diagnosed.
    missed_boundary,
};

/// Minimum number of inputs the fixer must change across all mutations.
/// Guards against a regression that stops the fixer from splitting at all,
/// which every property would otherwise pass.
const min_changed = 800;

const Example = struct {
    /// 1-based position in spec.txt, matching the numbering on the spec site.
    number: usize,
    section: []const u8,
    /// The text after "example" on the opening fence, e.g. "table"; empty
    /// for core CommonMark examples.
    extension: []const u8,
    markdown: []const u8,
};

/// spec.txt delimits each example with a fence of 32 backticks.
const fence = "`" ** 32;

/// Yields each example in spec.txt in order. `markdown` points into `arena`
/// because spec.txt writes tabs as "→" and they're replaced here.
const ExampleIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    arena: std.mem.Allocator,
    number: usize = 0,
    section: []const u8 = "",

    fn init(arena: std.mem.Allocator, text: []const u8) ExampleIterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n'), .arena = arena };
    }

    fn next(self: *ExampleIterator) !?Example {
        while (self.lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "#")) {
                self.section = std.mem.trimStart(u8, line, "# ");
                continue;
            }
            const opening = fence ++ " example";
            if (!std.mem.startsWith(u8, line, opening)) continue;

            self.number += 1;
            const extension = std.mem.trim(u8, line[opening.len..], " ");

            var markdown: std.ArrayListUnmanaged(u8) = .empty;
            while (self.lines.next()) |body| {
                if (std.mem.eql(u8, body, ".")) break;
                try markdown.appendSlice(self.arena, body);
                try markdown.append(self.arena, '\n');
            } else return error.UnterminatedExample;
            // Skip the expected HTML; it isn't used.
            while (self.lines.next()) |body| {
                if (std.mem.eql(u8, body, fence)) break;
            } else return error.UnterminatedExample;

            return .{
                .number = self.number,
                .section = self.section,
                .extension = extension,
                .markdown = try std.mem.replaceOwned(u8, self.arena, markdown.items, "→", "\t"),
            };
        }
        return null;
    }
};

fn fix(arena: std.mem.Allocator, source: []const u8) ![]u8 {
    var doc = try markz.parseWith(arena, source, .{ .gfm = true });
    const result = try reflow.analyze(arena, &doc);
    return reflow.applyInsertions(arena, source, result.insertions);
}

/// Render to HTML with every run of spaces, tabs, and newlines (all HTML
/// whitespace) collapsed to a single space, so a clause moved onto its own
/// line compares equal.
fn renderNormalized(arena: std.mem.Allocator, source: []const u8) ![]u8 {
    var doc = try markz.parseWith(arena, source, .{ .gfm = true });
    const html = try markz.renderHtml(arena, &doc);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var in_space = false;
    for (html) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            if (!in_space) try out.append(arena, ' ');
            in_space = true;
        } else {
            try out.append(arena, c);
            in_space = false;
        }
    }
    return out.items;
}

/// Apply `mutation` to every non-blank line of `markdown`.
fn mutate(arena: std.mem.Allocator, markdown: []const u8, mutation: Mutation) ![]const u8 {
    if (mutation == .none) return markdown;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try out.appendSlice(arena, line);
            continue;
        }
        switch (mutation) {
            .none => unreachable,
            .prefix_lines => {
                try out.appendSlice(arena, "Lead clause. ");
                try out.appendSlice(arena, line);
            },
            .suffix_lines => {
                try out.appendSlice(arena, line);
                try out.appendSlice(arena, " Tail clause.");
            },
            .insert_boundary => {
                const at = for (1..@max(line.len, 2) - 1) |i| {
                    if (line[i] == ' ' and std.ascii.isAlphanumeric(line[i - 1]) and std.ascii.isAlphanumeric(line[i + 1])) break i;
                } else null;
                if (at) |i| {
                    try out.appendSlice(arena, line[0..i]);
                    try out.appendSlice(arena, ". Next ");
                    try out.appendSlice(arena, line[i + 1 ..]);
                } else {
                    try out.appendSlice(arena, line);
                }
            },
        }
    }
    return out.items;
}

const Outcome = struct {
    changed: bool,
    /// A description of the first property violated, or null.
    failure: ?[]const u8,
};

fn check(arena: std.mem.Allocator, markdown: []const u8) !Outcome {
    const fixed = try fix(arena, markdown);
    const changed = !std.mem.eql(u8, markdown, fixed);
    const refixed = try fix(arena, fixed);
    if (!std.mem.eql(u8, fixed, refixed)) {
        return .{ .changed = changed, .failure = try std.fmt.allocPrint(arena, "not idempotent\n--- fixed ---\n{s}--- fixed again ---\n{s}", .{ fixed, refixed }) };
    }
    const before = try renderNormalized(arena, markdown);
    const after = try renderNormalized(arena, fixed);
    if (!std.mem.eql(u8, before, after)) {
        return .{ .changed = changed, .failure = try std.fmt.allocPrint(arena, "rendering changed\n--- fixed ---\n{s}--- html before ---\n{s}\n--- html after ---\n{s}\n", .{ fixed, before, after }) };
    }
    return .{ .changed = changed, .failure = null };
}

fn knownFailure(number: usize, mutation: Mutation) ?FailureReason {
    const key: InputKey = .{ .number = number, .mutation = mutation };
    const i = std.sort.binarySearch(KnownFailure, &known_failures, key, compareKey) orelse return null;
    return known_failures[i].reason;
}

test "GFM spec examples: fixing is idempotent and preserves rendering" {
    var spec_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer spec_arena.deinit();
    // Reset after every input so memory doesn't grow with the whole suite.
    var check_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer check_arena.deinit();

    var unexpected: usize = 0;
    var seen: usize = 0;
    var changed: usize = 0;
    var it = ExampleIterator.init(spec_arena.allocator(), spec);
    while (try it.next()) |example| {
        // The spec marks these as not passing in cmark-gfm itself.
        if (std.mem.eql(u8, example.extension, "disabled")) continue;
        seen += 1;

        for (std.enums.values(Mutation)) |mutation| {
            defer _ = check_arena.reset(.retain_capacity);
            const arena = check_arena.allocator();

            const markdown = try mutate(arena, example.markdown, mutation);
            const outcome = try check(arena, markdown);
            if (outcome.changed) changed += 1;
            const known_reason = knownFailure(example.number, mutation);
            if (outcome.failure) |msg| {
                if (known_reason != null) continue;
                unexpected += 1;
                std.debug.print(
                    "\n=== example {d} ({s}), mutation {t}: {s}\n--- markdown ---\n{s}",
                    .{ example.number, example.section, mutation, msg, markdown },
                );
            } else if (known_reason) |reason| {
                unexpected += 1;
                std.debug.print(
                    "\n=== example {d} ({s}), mutation {t} is listed in known_failures ({t}) but now passes; remove it\n",
                    .{ example.number, example.section, mutation, reason },
                );
            }
        }
    }

    // Guard against the parser silently matching nothing.
    try std.testing.expect(seen > 600);
    if (changed < min_changed) {
        std.debug.print(
            "\nonly {d} input(s) were changed by the fixer; expected at least {d}\n",
            .{ changed, min_changed },
        );
        unexpected += 1;
    }
    if (unexpected > 0) {
        std.debug.print("\n{d} GFM spec input(s) behaved unexpectedly\n", .{unexpected});
        return error.TestUnexpectedResult;
    }
}
