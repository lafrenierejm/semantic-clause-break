const std = @import("std");
const markz = @import("markz");
const clauses = @import("clauses.zig");

/// A single missing-line-break site: replace the `len` bytes at `at` (a run
/// of spaces) with a newline followed by `prefix` (the container marker for
/// continuation lines: "" at the top level, "> " per block-quote depth, or
/// spaces matching a list marker's width).
pub const Insertion = struct {
    at: usize,
    len: usize,
    prefix: []const u8,
};

pub const AnalyzeResult = struct {
    insertions: []Insertion,
};

/// Walk every paragraph in `doc` and report where an independent-clause
/// boundary exists mid-line instead of at an existing line break.
///
/// Text nodes inside block quotes and list items are copies with their
/// container markers already stripped (`markz` does not expose real file
/// offsets for them), so exact positions are recovered here by searching
/// forward through `doc.source` for each node's own text, in document
/// order. The search cursor only ever moves forward, so a node is never
/// matched against an earlier occurrence of the same text. If a node's text
/// can't be found (e.g. it was decoded from an HTML entity and so no longer
/// matches the source bytes verbatim), the rest of that paragraph is safely
/// skipped rather than guessed at.
pub fn analyze(allocator: std.mem.Allocator, doc: *const markz.Document) !AnalyzeResult {
    var insertions: std.ArrayListUnmanaged(Insertion) = .empty;
    var events_buf: std.ArrayListUnmanaged(markz.Event) = .empty;
    defer events_buf.deinit(allocator);
    var cursor: usize = 0;

    try walkBlock(allocator, doc, doc.root, &cursor, &insertions, &events_buf, true);

    return .{ .insertions = try insertions.toOwnedSlice(allocator) };
}

/// Apply `insertions` (must be sorted ascending by `at`) to `source`,
/// producing the fixed file contents.
pub fn applyInsertions(allocator: std.mem.Allocator, source: []const u8, insertions: []const Insertion) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var last: usize = 0;
    for (insertions) |ins| {
        try out.appendSlice(allocator, source[last..ins.at]);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, ins.prefix);
        last = ins.at + ins.len;
    }
    try out.appendSlice(allocator, source[last..]);

    return out.toOwnedSlice(allocator);
}

/// Only descend into containers that can hold prose (document, block
/// quotes, lists, list items). Headings, code blocks, HTML blocks, tables,
/// and thematic breaks are left untouched, per the tool's scope.
fn walkBlock(
    allocator: std.mem.Allocator,
    doc: *const markz.Document,
    node: *markz.Node,
    cursor: *usize,
    insertions: *std.ArrayListUnmanaged(Insertion),
    events_buf: *std.ArrayListUnmanaged(markz.Event),
    at_top_level: bool,
) !void {
    switch (node.tag) {
        .paragraph => {
            events_buf.clearRetainingCapacity();
            try collectParagraphEvents(allocator, node, events_buf);
            try processParagraph(allocator, doc, events_buf.items, cursor, insertions, at_top_level);
        },
        .document, .block_quote, .list, .list_item => {
            // Once nested in a block quote or list, a paragraph's true line
            // prefix (the quote marker or list continuation indent) can't
            // be assumed empty, unlike top-level content.
            const child_at_top_level = at_top_level and node.tag == .document;
            var child = node.first_child;
            while (child) |c| {
                try walkBlock(allocator, doc, c, cursor, insertions, events_buf, child_at_top_level);
                child = c.next;
            }
        },
        else => {},
    }
}

fn collectParagraphEvents(allocator: std.mem.Allocator, para: *markz.Node, out: *std.ArrayListUnmanaged(markz.Event)) !void {
    var iter = markz.TreeIterator.init(para);
    while (iter.next()) |event| {
        try out.append(allocator, event);
        switch (event) {
            .exit => |node| if (node == para) return,
            else => {},
        }
    }
}

/// True if there is more paragraph content on the current logical line
/// after `events[idx]`, i.e. scanning forward hits real content before a
/// soft/hard break (or the paragraph simply ends).
fn hasMoreContentAfter(events: []const markz.Event, idx: usize) bool {
    var i = idx + 1;
    while (i < events.len) : (i += 1) {
        switch (events[i]) {
            .leaf => |node| {
                if (node.tag == .soft_break or node.tag == .hard_break) return false;
                return true;
            },
            .enter => return true,
            .exit => {},
        }
    }
    return false;
}

fn processParagraph(
    allocator: std.mem.Allocator,
    doc: *const markz.Document,
    events: []const markz.Event,
    cursor: *usize,
    insertions: *std.ArrayListUnmanaged(Insertion),
    at_top_level: bool,
) !void {
    // At the top level a paragraph has no container marker, so the prefix
    // is always known to be empty; only block-quote/list nesting requires
    // recovering it from where the line's first node actually sits.
    const empty_prefix: ?[]const u8 = if (at_top_level) "" else null;
    var line_prefix: ?[]const u8 = empty_prefix;
    // True once inline markup (emphasis/strong/link/code-span delimiters,
    // etc.) has been seen on the current logical line. A text node reached
    // while this is set does not sit at the true start of the line, so its
    // position can't be used to recover a container prefix (e.g. the
    // opening backtick of a leading code span would otherwise be mistaken
    // for line content and get "repeated" on inserted lines).
    var seen_markup_since_break = false;
    var boundaries: std.ArrayListUnmanaged(clauses.Boundary) = .empty;
    defer boundaries.deinit(allocator);

    for (events, 0..) |event, idx| {
        const node = switch (event) {
            .enter => |n| {
                if (n.tag != .paragraph) seen_markup_since_break = true;
                continue;
            },
            .exit => continue,
            .leaf => |n| n,
        };

        if (node.tag == .soft_break or node.tag == .hard_break) {
            line_prefix = empty_prefix;
            seen_markup_since_break = false;
            continue;
        }

        const is_text_like = switch (node.tag) {
            .text, .code_span, .autolink, .html_inline, .critic_comment, .obsidian_tag => true,
            else => false,
        };
        if (!is_text_like) continue;

        const text = doc.nodeText(node);
        if (text.len == 0) continue;

        const found = std.mem.indexOf(u8, doc.source[cursor.*..], text) orelse return;
        const real_start = cursor.* + found;
        cursor.* = real_start + text.len;

        if (line_prefix == null and node.tag == .text and !seen_markup_since_break) {
            const line_start = if (std.mem.lastIndexOfScalar(u8, doc.source[0..real_start], '\n')) |p| p + 1 else 0;
            const raw_prefix = doc.source[line_start..real_start];
            line_prefix = try continuationPrefix(allocator, raw_prefix);
        }
        // Only the very first content-bearing node of a line can be used to
        // recover its prefix; anything after it (of any tag) no longer sits
        // at the true start of the line.
        seen_markup_since_break = true;

        if (node.tag != .text) continue;

        boundaries.clearRetainingCapacity();
        try clauses.findBoundaries(allocator, text, &boundaries);
        if (line_prefix == null) continue;
        for (boundaries.items) |b| {
            const has_more_after = if (b.end < text.len) true else hasMoreContentAfter(events, idx);
            if (!has_more_after) continue;
            try insertions.append(allocator, .{
                .at = real_start + b.start,
                .len = b.end - b.start,
                .prefix = line_prefix.?,
            });
        }
    }
}

/// Convert a captured line prefix into the form new continuation lines
/// should use: block-quote markers ("> ") repeat verbatim, but a list
/// marker (bullet or ordinal) becomes equal-width spaces so a mid-item
/// split doesn't start a new list item.
fn continuationPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var end = prefix.len;
    while (end > 0 and prefix[end - 1] == ' ') : (end -= 1) {}
    if (end == 0) return prefix;

    var start = end;
    while (start > 0 and prefix[start - 1] != ' ') : (start -= 1) {}
    const token = prefix[start..end];

    const is_bullet = token.len == 1 and (token[0] == '-' or token[0] == '*' or token[0] == '+');
    var is_ordinal = false;
    if (!is_bullet and token.len >= 2) {
        const last = token[token.len - 1];
        if (last == '.' or last == ')') {
            is_ordinal = true;
            for (token[0 .. token.len - 1]) |c| {
                if (!std.ascii.isDigit(c)) {
                    is_ordinal = false;
                    break;
                }
            }
        }
    }
    if (!is_bullet and !is_ordinal) return prefix;

    const out = try allocator.dupe(u8, prefix);
    @memset(out[start..end], ' ');
    return out;
}

fn expectFixed(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var doc = try markz.parseWith(allocator, source, .{ .gfm = true });
    const result = try analyze(allocator, &doc);
    const fixed = try applyInsertions(allocator, source, result.insertions);
    try std.testing.expectEqualStrings(expected, fixed);
}

test "splits a simple paragraph" {
    try expectFixed(
        "First clause. Second clause.",
        "First clause.\nSecond clause.",
    );
}

test "leaves already-split text alone" {
    try expectFixed(
        "First clause.\nSecond clause.",
        "First clause.\nSecond clause.",
    );
}

test "splits inside a block quote, repeating the marker" {
    try expectFixed(
        "> First clause. Second clause.",
        "> First clause.\n> Second clause.",
    );
}

test "splits inside a list item, using spaces for continuation" {
    try expectFixed(
        "- First clause. Second clause.",
        "- First clause.\n  Second clause.",
    );
}

test "splits across an inline emphasis boundary" {
    try expectFixed(
        "This ends here. *Then* more text.",
        "This ends here.\n*Then* more text.",
    );
}

test "heading and code block are left untouched" {
    const source = "# Title. Not touched.\n\n```\ncode. still code.\n```\n";
    try expectFixed(source, source);
}

test "does not split a table" {
    const source = "| A | B |\n|---|---|\n| one, but two | x |\n";
    try expectFixed(source, source);
}

test "paragraph starting with a code span does not leak its backtick into the prefix" {
    try expectFixed(
        "`code` here is a sentence. And another sentence follows.",
        "`code` here is a sentence.\nAnd another sentence follows.",
    );
}

test "paragraph starting with emphasis does not leak its marker into the prefix" {
    try expectFixed(
        "*emphasis* here is a sentence. And another sentence follows.",
        "*emphasis* here is a sentence.\nAnd another sentence follows.",
    );
}

test "list item paragraph starting with a code span is left alone rather than guessed at" {
    const source = "- `code` here is a sentence. And another sentence follows.";
    try expectFixed(source, source);
}
