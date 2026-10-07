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
    /// Source offset (at or after `at + len`) before which a backslash is
    /// written, so punctuation that would start a block on the new line
    /// (e.g. "#" or the "." in "1.") is read as text instead.
    escape: ?usize = null,
};

pub const AnalyzeResult = struct {
    insertions: []Insertion,
};

pub const Options = struct {
    /// Where a break would make the next clause start a block, escape the
    /// syntax responsible instead of leaving the clause on its line.
    escape: bool = true,
};

/// Walk every paragraph in `doc` and report where an independent-clause
/// boundary exists mid-line instead of at an existing line break.
///
/// Text nodes inside block quotes and list items are copies with their
/// container markers already stripped (`markz` does not expose real file
/// offsets for them), so exact positions are recovered here by searching
/// forward through `doc.source` for each node's own text, in document
/// order. The search cursor only ever moves forward, so a node is never
/// matched against an earlier occurrence of the same text. A text node's
/// content is decoded, so backslash escapes are allowed for when
/// matching it (see `findText`). If a node's text still can't be found
/// (e.g. it was decoded from an HTML entity), the rest of that paragraph
/// is safely skipped rather than guessed at.
///
/// A boundary is only reported if breaking the line there leaves the
/// rendered document unchanged; see `keepRenderPreserving`.
pub fn analyze(allocator: std.mem.Allocator, doc: *const markz.Document, options: Options) !AnalyzeResult {
    var candidates: std.ArrayListUnmanaged(Insertion) = .empty;
    defer candidates.deinit(allocator);
    var events_buf: std.ArrayListUnmanaged(markz.Event) = .empty;
    defer events_buf.deinit(allocator);
    var cursor: usize = 0;

    try walkBlock(allocator, doc, doc.root, &cursor, &candidates, &events_buf, true, true);

    return .{ .insertions = try keepRenderPreserving(allocator, doc, candidates.items, options) };
}

/// Return the subset of `candidates` (sorted ascending by `at`) that can be
/// applied together without changing how `doc` renders, ignoring
/// differences in whitespace.
///
/// Breaking a line can change the document's structure: the next clause
/// may start with block syntax (a list marker, "#", ">", a code fence, an
/// HTML block tag), or the line left behind may become a setext underline
/// or table delimiter row. Rather than encode every such rule, markz is
/// asked directly, in two stages:
///
/// 1. Each candidate is checked locally (see `continuesParagraph`): the
///    common case of a split starting a new block is caught without
///    rendering the whole document, which would make a large file with many
///    such candidates quadratic. If `options.escape` is set, such a
///    candidate is retried with its leading syntax escaped (see
///    `escapeOffset`), and only rejected if that fails too.
/// 2. Effects aren't always local (e.g. a line left behind becoming a table
///    delimiter row), so the survivors are applied together and the whole
///    document is re-rendered and compared. That normally costs one render.
///    If it fails, candidates are accepted greedily in document order and a
///    range that fails is bisected, so each unsafe candidate costs O(log n)
///    more renders.
///
/// A candidate that's unsafe alone can become safe once a later one is
/// accepted (e.g. breaking before "1. foo" starts a list, but not once
/// "1." is also broken off, since an empty list item can't interrupt a
/// paragraph). Rejected candidates are retried until a round accepts none,
/// so the result is the same as running the fixer on its own output.
fn keepRenderPreserving(allocator: std.mem.Allocator, doc: *const markz.Document, candidates: []Insertion, options: Options) ![]Insertion {
    if (candidates.len == 0) return allocator.alloc(Insertion, 0);

    const original = try markz.renderHtml(allocator, doc);
    defer allocator.free(original);

    var check: RenderCheck = .{
        .scratch = std.heap.ArenaAllocator.init(allocator),
        .source = doc.source,
        .original = original,
        .candidates = candidates,
        .keep = try allocator.alloc(bool, candidates.len),
        .trial = .empty,
    };
    defer check.scratch.deinit();
    defer allocator.free(check.keep);
    defer check.trial.deinit(allocator);
    @memset(check.keep, false);

    var pending: std.ArrayListUnmanaged(usize) = .empty;
    defer pending.deinit(allocator);
    for (candidates, 0..) |*c, i| {
        // The new line runs to the next candidate (assumed accepted too) or
        // to the end of the current line.
        const start = c.at + c.len;
        const line_end = std.mem.indexOfScalarPos(u8, doc.source, start, '\n') orelse doc.source.len;
        const end = if (i + 1 < candidates.len) @min(candidates[i + 1].at, line_end) else line_end;
        const line = doc.source[start..end];
        if (try continuesParagraph(&check.scratch, line, null)) {
            try pending.append(allocator, i);
            continue;
        }
        if (!options.escape) continue;
        const offset = escapeOffset(line) orelse continue;
        if (try continuesParagraph(&check.scratch, line, offset)) {
            c.escape = start + offset;
            try pending.append(allocator, i);
        }
    }

    while (pending.items.len > 0) {
        try check.acceptRange(allocator, pending.items);
        const before = pending.items.len;
        var write: usize = 0;
        for (pending.items) |i| {
            if (check.keep[i]) continue;
            pending.items[write] = i;
            write += 1;
        }
        pending.shrinkRetainingCapacity(write);
        if (write == before) break;
    }

    var accepted: std.ArrayListUnmanaged(Insertion) = .empty;
    defer accepted.deinit(allocator);
    for (candidates, check.keep) |c, keep| {
        if (keep) try accepted.append(allocator, c);
    }
    return accepted.toOwnedSlice(allocator);
}

const RenderCheck = struct {
    scratch: std.heap.ArenaAllocator,
    source: []const u8,
    original: []const u8,
    candidates: []const Insertion,
    /// Which candidates are accepted so far.
    keep: []bool,
    /// Reused buffer for the candidates under trial.
    trial: std.ArrayListUnmanaged(Insertion),

    /// Accept `range` (indices into `candidates`) if applying it alongside
    /// everything already accepted renders the same; otherwise bisect it.
    fn acceptRange(self: *RenderCheck, allocator: std.mem.Allocator, range: []const usize) !void {
        for (range) |i| self.keep[i] = true;
        if (try self.rendersSame(allocator)) return;
        for (range) |i| self.keep[i] = false;

        if (range.len == 1) return;
        const mid = range.len / 2;
        try self.acceptRange(allocator, range[0..mid]);
        try self.acceptRange(allocator, range[mid..]);
    }

    fn rendersSame(self: *RenderCheck, allocator: std.mem.Allocator) !bool {
        self.trial.clearRetainingCapacity();
        for (self.candidates, self.keep) |c, keep| {
            if (keep) try self.trial.append(allocator, c);
        }

        defer _ = self.scratch.reset(.retain_capacity);
        const arena = self.scratch.allocator();
        const fixed = try applyInsertions(arena, self.source, self.trial.items);
        var doc = try markz.parseWith(arena, fixed, .{ .gfm = true });
        const html = try markz.renderHtml(arena, &doc);
        return eqlCollapsingWhitespace(self.original, html);
    }
};

/// True if `line`, placed on the line after a paragraph's first line, is
/// still part of that paragraph rather than starting a new block (or turning
/// the paragraph into something else, like a setext heading or table). If
/// `escape` is set, a backslash is written before that offset in `line`, as
/// `Insertion.escape` would.
fn continuesParagraph(scratch: *std.heap.ArenaAllocator, line: []const u8, escape: ?usize) !bool {
    defer _ = scratch.reset(.retain_capacity);
    const arena = scratch.allocator();
    const split = escape orelse line.len;
    const backslash: []const u8 = if (escape != null) "\\" else "";
    const probe = try std.mem.concat(arena, u8, &.{ "p\n", line[0..split], backslash, line[split..] });
    const doc = try markz.parseWith(arena, probe, .{ .gfm = true });
    const first = doc.root.first_child orelse return false;
    return first.tag == .paragraph and first.next == null;
}

/// Where to put a backslash in `line` so its leading block syntax reads as
/// text: before leading punctuation (e.g. "#", "-", ">"), or after the
/// digits of an ordered list marker ("1." becomes "1\."). Null if there's
/// nothing to escape, or if escaping would change how the line renders:
/// a "<" that starts an HTML block is raw HTML in the original paragraph,
/// and escaping one backtick of a fence changes the code span it opens.
fn escapeOffset(line: []const u8) ?usize {
    if (line.len == 0) return null;
    const first = line[0];
    if (first == '<' or first == '`') return null;
    if (std.ascii.isPunctuation(first)) return 0;
    if (!std.ascii.isDigit(first)) return null;
    var i: usize = 1;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i < line.len and (line[i] == '.' or line[i] == ')')) return i;
    return null;
}

/// Compare `a` and `b`, treating every run of spaces, tabs, and newlines as
/// a single space. A soft line break renders as a newline where the
/// original rendered a space, and HTML treats the two the same.
fn eqlCollapsingWhitespace(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const a_space = i < a.len and isHtmlSpace(a[i]);
        const b_space = j < b.len and isHtmlSpace(b[j]);
        if (a_space != b_space) return false;
        if (a_space) {
            while (i < a.len and isHtmlSpace(a[i])) i += 1;
            while (j < b.len and isHtmlSpace(b[j])) j += 1;
            continue;
        }
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

fn isHtmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
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
        if (ins.escape) |escape| {
            try out.appendSlice(allocator, source[last..escape]);
            try out.append(allocator, '\\');
            last = escape;
        }
    }
    try out.appendSlice(allocator, source[last..]);

    return out.toOwnedSlice(allocator);
}

/// Only descend into containers that can hold prose (document, block
/// quotes, lists, list items). Headings, code blocks, HTML blocks, tables,
/// and thematic breaks are left untouched, per the tool's scope.
///
/// `spans_are_offsets` is false inside list items. markz re-parses list items'
/// contents from a marker-stripped copy, so descendant spans are relative to
/// that copy rather than to `doc.source`.
fn walkBlock(
    allocator: std.mem.Allocator,
    doc: *const markz.Document,
    node: *markz.Node,
    cursor: *usize,
    insertions: *std.ArrayListUnmanaged(Insertion),
    events_buf: *std.ArrayListUnmanaged(markz.Event),
    at_top_level: bool,
    spans_are_offsets: bool,
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
            const child_spans_are_offsets = spans_are_offsets and node.tag != .list_item;
            var child = node.first_child;
            while (child) |c| {
                try walkBlock(allocator, doc, c, cursor, insertions, events_buf, child_at_top_level, child_spans_are_offsets);
                child = c.next;
            }
        },
        // Move the search cursor past skipped blocks.
        else => if (spans_are_offsets) {
            cursor.* = @max(cursor.*, node.source.end);
        },
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
    // For the current text node, the source offset of each byte of its
    // (decoded) text, plus one for its end; see `findText`.
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    defer offsets.deinit(allocator);

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

        const real_start = if (node.tag == .text) start: {
            try offsets.resize(allocator, text.len + 1);
            const start = findText(doc.source, cursor.*, text, offsets.items) orelse return;
            cursor.* = offsets.items[text.len];
            break :start start;
        } else start: {
            const found = std.mem.indexOf(u8, doc.source[cursor.*..], text) orelse return;
            cursor.* = cursor.* + found + text.len;
            break :start cursor.* - text.len;
        };

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
            // A boundary is a run of spaces, which are never escaped, so its
            // source span is exactly as long as its decoded one.
            const at = offsets.items[b.start];
            try insertions.append(allocator, .{
                .at = at,
                .len = offsets.items[b.end] - at,
                .prefix = line_prefix.?,
            });
        }
    }
}

/// Find the first occurrence at or after `from` in `source` of `text`, a text
/// node's decoded content, and return its start. In a text node, a
/// backslash followed by ASCII punctuation is always an escape, so "\*" in
/// the source decodes to "*" in `text`. `offsets` (`text.len + 1` long)
/// receives the source offset of each byte of `text` and, last, the end of
/// the match, so positions found in `text` can be mapped back to `source`.
fn findText(source: []const u8, from: usize, text: []const u8, offsets: []usize) ?usize {
    var start = from;
    while (start < source.len) : (start += 1) {
        if (matchText(source, start, text, offsets)) return start;
    }
    return null;
}

fn matchText(source: []const u8, start: usize, text: []const u8, offsets: []usize) bool {
    var i = start;
    for (text, 0..) |c, k| {
        if (i >= source.len) return false;
        offsets[k] = i;
        if (source[i] == '\\' and i + 1 < source.len and std.ascii.isPunctuation(source[i + 1])) {
            if (source[i + 1] != c) return false;
            i += 2;
        } else {
            if (source[i] != c) return false;
            i += 1;
        }
    }
    offsets[text.len] = i;
    return true;
}

/// Convert a captured line prefix into the form new continuation lines
/// should use. Block-quote markers ("> ") repeat verbatim, but every list
/// marker (bullet or ordinal) becomes equal-width spaces so a mid-item
/// split doesn't start a new list item.
fn continuationPrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var out: ?[]u8 = null;
    var it = std.mem.tokenizeScalar(u8, prefix, ' ');
    while (it.next()) |token| {
        if (!isListMarker(token)) continue;
        const buf = out orelse try allocator.dupe(u8, prefix);
        out = buf;
        const start = @intFromPtr(token.ptr) - @intFromPtr(prefix.ptr);
        @memset(buf[start..][0..token.len], ' ');
    }
    return out orelse prefix;
}

fn isListMarker(token: []const u8) bool {
    if (token.len == 1) return token[0] == '-' or token[0] == '*' or token[0] == '+';
    const last = token[token.len - 1];
    if (last != '.' and last != ')') return false;
    for (token[0 .. token.len - 1]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn expectFixed(source: []const u8, expected: []const u8) !void {
    try expectFixedWith(.{}, source, expected);
}

fn expectFixedWith(options: Options, source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var doc = try markz.parseWith(allocator, source, .{ .gfm = true });
    const result = try analyze(allocator, &doc, options);
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

test "paragraph text duplicated in a preceding heading splits the paragraph, not the heading" {
    try expectFixed(
        "# Hi. There\n\nHi. There\n",
        "# Hi. There\n\nHi.\nThere\n",
    );
}

test "paragraph text duplicated in a preceding code block splits the paragraph, not the code" {
    try expectFixed(
        "```\nA. B\n```\n\nA. B\n",
        "```\nA. B\n```\n\nA.\nB\n",
    );
}

test "block quote inside a list item blanks the list marker but keeps the quote marker" {
    try expectFixed(
        "- > First clause. Second clause.",
        "- > First clause.\n  > Second clause.",
    );
}

test "nested list item blanks every list marker in the prefix" {
    try expectFixed(
        "1. - First clause. Second clause.",
        "1. - First clause.\n     Second clause.",
    );
}

test "escapes a leading '#' that would start a heading" {
    try expectFixed(
        "See below. # Not a heading",
        "See below.\n\\# Not a heading",
    );
}

test "escapes a leading '-' that would start a list item" {
    try expectFixed(
        "Steps follow. - Open the file",
        "Steps follow.\n\\- Open the file",
    );
}

test "escapes the delimiter, not the digit, of an ordered list marker" {
    try expectFixed(
        "Steps follow. 1) Open the file",
        "Steps follow.\n1\\) Open the file",
    );
}

test "escapes a leading '>' that would start a block quote" {
    try expectFixed(
        "As they said: > quoted text",
        "As they said:\n\\> quoted text",
    );
}

test "escapes a line that would underline a setext heading" {
    try expectFixed(
        "First clause. Second clause.\nThird clause. ---",
        "First clause.\nSecond clause.\nThird clause.\n\\---",
    );
}

test "does not split where escaping a code fence would change its code span" {
    const source = "Run this. ``` code";
    try expectFixed(source, source);
}

test "does not split where escaping an HTML block tag would show it as text" {
    const source = "See this. <div>";
    try expectFixed(source, source);
}

test "does not split or escape block syntax when escaping is off" {
    const source = "See below. # Not a heading";
    try expectFixedWith(.{ .escape = false }, source, source);
}

test "keeps safe splits in a paragraph that also has an unsafe one when escaping is off" {
    try expectFixedWith(
        .{ .escape = false },
        "First clause. Second clause. # Not a heading",
        "First clause.\nSecond clause. # Not a heading",
    );
}

test "splits after backslash escapes, at the boundary's position in the source" {
    try expectFixed(
        "Use \\*stars\\* here. Then more.",
        "Use \\*stars\\* here.\nThen more.",
    );
}

test "escaped text is matched on its own line, not a later line with the same decoded text" {
    try expectFixed(
        "Lead clause. \\[foo]\nLead clause. [foo]",
        "Lead clause.\n\\[foo]\nLead clause.\n[foo]",
    );
}

test "a backslash before a non-punctuation character is literal text" {
    try expectFixed(
        "Path C:\\dir here. Then more.",
        "Path C:\\dir here.\nThen more.",
    );
}
