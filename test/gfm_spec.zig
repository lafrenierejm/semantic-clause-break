//! Parsing of the GFM spec's examples (`test/spec.txt` from cmark-gfm), and
//! the mutations each example is run through. Shared by the test generator
//! (`gen_spec_tests.zig`) and the checks it calls (`spec_check.zig`), so it
//! only depends on `std`.

const std = @import("std");

/// Ways of deriving more inputs from a spec example. Blank lines are left
/// alone by every mutation so the example's block structure survives. One
/// test is generated per example per mutation.
pub const Mutation = enum {
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

pub const Example = struct {
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
pub const ExampleIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    arena: std.mem.Allocator,
    number: usize = 0,
    section: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, text: []const u8) ExampleIterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n'), .arena = arena };
    }

    pub fn next(self: *ExampleIterator) !?Example {
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
