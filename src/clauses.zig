const std = @import("std");

/// A run of whitespace within a text node that should become a line break.
/// `start`/`end` are byte offsets into the text that was scanned.
pub const Boundary = struct {
    start: usize,
    end: usize,
};

const abbreviations = [_][]const u8{
    "dr",
    "eg",
    "ie",
    "jr",
    "mr",
    "mrs",
    "ms",
    "prof",
    "sr",
    "vs",
};

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Walk backward from `end` (exclusive) collecting a run of ASCII letters and
/// interior '.' characters, then check it against a small abbreviation list
/// (dots stripped, case-insensitive). Used to suppress false sentence breaks
/// like "Dr. Smith".
fn endsWithAbbreviation(text: []const u8, end: usize) bool {
    var start = end;
    while (start > 0) {
        const c = text[start - 1];
        if (isAlnum(c) or c == '.') {
            start -= 1;
        } else {
            break;
        }
    }
    if (start == end) return false;

    var buf: [16]u8 = undefined;
    var len: usize = 0;
    for (text[start..end]) |c| {
        if (c == '.') continue;
        if (len >= buf.len) return false;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    const word = buf[0..len];
    for (abbreviations) |abbr| {
        if (std.mem.eql(u8, word, abbr)) return true;
    }
    return false;
}

/// Skip closing quote/paren characters that commonly trail sentence-ending
/// punctuation, e.g. `He said "stop." Then left.`
fn skipClosers(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"', '\'', ')', ']', 0xe2 => {
                // 0xe2 covers the lead byte of UTF-8 smart quotes (e.g. ” ’);
                // treat any of the three-byte sequence as a single closer.
                if (text[i] == 0xe2) {
                    if (i + 2 < text.len) i += 2 else return i;
                }
            },
            else => return i,
        }
    }
    return i;
}

/// Scan `text` for independent-clause boundaries and append the whitespace
/// run that should become a line break to `out`. A boundary reported with
/// `end == text.len` means the break candidate sits at the end of this text
/// node; the caller must decide (based on what follows in the tree) whether
/// there is more content on the same logical line before acting on it.
pub fn findBoundaries(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged(Boundary)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '.', '!', '?' => {
                if (endsWithAbbreviation(text, i)) {
                    i += 1;
                    continue;
                }
                const after_closers = skipClosers(text, i + 1);
                if (after_closers < text.len and text[after_closers] == ' ') {
                    var end = after_closers;
                    while (end < text.len and text[end] == ' ') end += 1;
                    try out.append(allocator, .{ .start = after_closers, .end = end });
                    i = end;
                    continue;
                }
            },
            ';' => {
                if (i + 1 < text.len and text[i + 1] == ' ') {
                    var end = i + 1;
                    while (end < text.len and text[end] == ' ') end += 1;
                    try out.append(allocator, .{ .start = i + 1, .end = end });
                    i = end;
                    continue;
                }
            },
            ':' => {
                const prev_is_digit = i > 0 and std.ascii.isDigit(text[i - 1]);
                const next_is_digit = i + 1 < text.len and std.ascii.isDigit(text[i + 1]);
                if (!prev_is_digit and !next_is_digit and i + 1 < text.len and text[i + 1] == ' ') {
                    var end = i + 1;
                    while (end < text.len and text[end] == ' ') end += 1;
                    try out.append(allocator, .{ .start = i + 1, .end = end });
                    i = end;
                    continue;
                }
            },
            else => {},
        }
        i += 1;
    }
}

fn expectBoundaries(text: []const u8, expected: []const Boundary) !void {
    var out: std.ArrayListUnmanaged(Boundary) = .empty;
    defer out.deinit(std.testing.allocator);
    try findBoundaries(std.testing.allocator, text, &out);
    try std.testing.expectEqualSlices(Boundary, expected, out.items);
}

test "sentence end splits" {
    try expectBoundaries("First clause. Second clause.", &.{.{ .start = 13, .end = 14 }});
}

test "no split without following content" {
    try expectBoundaries("Ends here.", &.{});
}

test "semicolon splits" {
    try expectBoundaries("One thing; another thing.", &.{.{ .start = 10, .end = 11 }});
}

test "colon splits but not a time" {
    try expectBoundaries("Consider this: an example.", &.{.{ .start = 14, .end = 15 }});
    try expectBoundaries("It is 3:00 now.", &.{});
}

test "comma with coordinating conjunction does not split (avoids Oxford-comma false positives)" {
    try expectBoundaries("This is one clause, and this is another.", &.{});
}

test "plain list comma does not split" {
    try expectBoundaries("apples, oranges, and bananas", &.{});
}

test "abbreviation does not split" {
    try expectBoundaries("Dr. Smith arrived.", &.{});
}

test "e.g. does not split" {
    try expectBoundaries("Bring snacks, e.g. chips.", &.{});
}

test "decimal number does not split" {
    try expectBoundaries("Pi is 3.14 approximately.", &.{});
}

test "quoted sentence end splits" {
    try expectBoundaries("He said \"stop.\" Then left.", &.{.{ .start = 15, .end = 16 }});
}

test "multiple boundaries" {
    try expectBoundaries(
        "One. Two; three four.",
        &.{
            .{ .start = 4, .end = 5 },
            .{ .start = 9, .end = 10 },
        },
    );
}
