const std = @import("std");

/// A run of whitespace within a text node that should become a line break.
/// `start`/`end` are byte offsets into the text that was scanned.
pub const Boundary = struct {
    start: usize,
    end: usize,
};

// All abbreviations are copied from pySBD under terms of its MIT license.
// https://github.com/nipunsadvilkar/pySBD/blob/5905f13be4fc95f407b98392e0ec303617a33d86/pysbd/lang/common/standard.py#L26-L28
//
// The general list: a trailing period after any of these is always treated
// as part of the abbreviation, never a sentence end.
const abbreviations = [_][]const u8{
    "adj",
    "adm",
    "adv",
    "al",
    "ala",
    "alta",
    "apr",
    "arc",
    "ariz",
    "ark",
    "art",
    "assn",
    "asst",
    "attys",
    "aug",
    "ave",
    "bart",
    "bld",
    "bldg",
    "blvd",
    "brig",
    "bros",
    "btw",
    "cal",
    "calif",
    "capt",
    "cl",
    "cmdr",
    "co",
    "col",
    "colo",
    "comdr",
    "con",
    "conn",
    "corp",
    "cpl",
    "cres",
    "ct",
    "d.phil",
    "dak",
    "dec",
    "del",
    "dept",
    "det",
    "dist",
    "dr",
    "dr.phil",
    "dr.philos",
    "drs",
    "e.g",
    "ens",
    "esp",
    "esq",
    "etc",
    "exp",
    "expy",
    "ext",
    "feb",
    "fed",
    "fla",
    "ft",
    "fwy",
    "fy",
    "ga",
    "gen",
    "gov",
    "hon",
    "hosp",
    "hr",
    "hway",
    "hwy",
    "i.e",
    "ia",
    "id",
    "ida",
    "ill",
    "inc",
    "ind",
    "ing",
    "insp",
    "is",
    "jan",
    "jr",
    "jul",
    "jun",
    "kan",
    "kans",
    "ken",
    "ky",
    "la",
    "lt",
    "ltd",
    "maj",
    "man",
    "mar",
    "mass",
    "may",
    "md",
    "me",
    "med",
    "messrs",
    "mex",
    "mfg",
    "mich",
    "min",
    "minn",
    "miss",
    "mlle",
    "mm",
    "mme",
    "mo",
    "mont",
    "mr",
    "mrs",
    "ms",
    "msgr",
    "mssrs",
    "mt",
    "mtn",
    "neb",
    "nebr",
    "nev",
    "no",
    "nos",
    "nov",
    "nr",
    "oct",
    "ok",
    "okla",
    "ont",
    "op",
    "ord",
    "ore",
    "p",
    "pa",
    "pd",
    "pde",
    "penn",
    "penna",
    "pfc",
    "ph",
    "ph.d",
    "pl",
    "plz",
    "pp",
    "prof",
    "pvt",
    "que",
    "rd",
    "rs",
    "ref",
    "rep",
    "reps",
    "res",
    "rev",
    "rt",
    "sask",
    "sec",
    "sen",
    "sens",
    "sep",
    "sept",
    "sfc",
    "sgt",
    "sr",
    "st",
    "supt",
    "surg",
    "tce",
    "tenn",
    "tex",
    "univ",
    "usafa",
    "u.s",
    "ut",
    "va",
    "v",
    "ver",
    "viz",
    "vs",
    "vt",
    "wash",
    "wis",
    "wisc",
    "wy",
    "wyo",
    "yuk",
    "fig",
};
// Titles that always precede a name ("Mr.", "Gen.", "Dr.", ...), so a
// following capitalized word never signals a new sentence. Currently a
// subset of `abbreviations`; kept separate so the two lists can diverge and
// so this list's entries are exempt from the digit requirement below.
const prepositive_abbreviations = [_][]const u8{
    "adm",
    "attys",
    "brig",
    "capt",
    "cmdr",
    "col",
    "cpl",
    "det",
    "dr",
    "gen",
    "gov",
    "ing",
    "lt",
    "maj",
    "mr",
    "mrs",
    "ms",
    "mt",
    "messrs",
    "mssrs",
    "prof",
    "ph",
    "rep",
    "reps",
    "rev",
    "sen",
    "sens",
    "sgt",
    "st",
    "supt",
    "v",
    "vs",
    "fig",
};
// Short tokens ("no", "p", "art", ...) that are too common as ordinary
// words or sentence-final abbreviations to suppress unconditionally; a
// trailing period only counts as part of the abbreviation when a number
// follows (e.g. "No. 5"), so this list is checked separately from, and
// takes priority over, `abbreviations`.
const number_abbreviations = [_][]const u8{
    "art",
    "ext",
    "no",
    "nos",
    "p",
    "pp",
};

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn listContains(list: []const []const u8, word: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, word, entry)) return true;
    }
    return false;
}

/// Walk backward from `end` (exclusive) collecting a run of ASCII letters and
/// interior '.' characters (e.g. "e.g" or "U.S"), lowercase it, and check it
/// against the abbreviation lists (case-insensitive). `followed_by_number`
/// is whether a digit (skipping spaces) follows the punctuation at `end`.
///
/// `number_abbreviations` holds short, otherwise-ambiguous tokens ("no",
/// "p", "art", ...) that only reliably indicate an abbreviation when a
/// number follows (e.g. "No. 5"); on their own they're too common as
/// ordinary words to blanket-suppress. `abbreviations` and
/// `prepositive_abbreviations` (titles that always precede a name, like
/// "Mr.", "Gen.") are suppressed unconditionally.
fn endsWithAbbreviation(text: []const u8, end: usize, followed_by_number: bool) bool {
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
        if (len >= buf.len) return false;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    const word = buf[0..len];

    if (listContains(&number_abbreviations, word)) return followed_by_number;
    return listContains(&abbreviations, word) or listContains(&prepositive_abbreviations, word);
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
                const followed_by_number = blk: {
                    var j = i + 1;
                    while (j < text.len and text[j] == ' ') : (j += 1) {}
                    break :blk j < text.len and std.ascii.isDigit(text[j]);
                };
                if (endsWithAbbreviation(text, i, followed_by_number)) {
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

test "prepositive abbreviation does not split" {
    try expectBoundaries("Gen. Smith arrived.", &.{});
}

test "number abbreviation only suppresses when followed by a number" {
    try expectBoundaries("See p. 5 for details.", &.{});
    try expectBoundaries(
        "This ends on p. Nothing follows.",
        &.{.{ .start = 15, .end = 16 }},
    );
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
