//! GFM spec example/mutation pairs known to fail, each with the reason.
//! `gen_spec_tests.zig` generates their tests to check that they still fail
//! and then report themselves as skipped. An entry that starts passing fails
//! its test instead, so this list can't go stale. Only depends on `std`, so
//! the generator can import it.

const std = @import("std");
const Mutation = @import("gfm_spec.zig").Mutation;

/// Entries must be in strictly increasing (number, mutation) order, which
/// is checked at compile time and also rules out duplicates. `lookup`
/// relies on that order to binary search.
pub const entries = [_]KnownFailure{
    .{ .number = 164, .mutation = .insert_boundary, .reason = .ref_def_label },
    .{ .number = 181, .mutation = .prefix_lines, .reason = .code_span_match },
};

pub const KnownFailure = struct { number: usize, mutation: Mutation, reason: FailureReason };

/// Why an entry in `entries` fails.
pub const FailureReason = enum {
    /// The paragraph's text also appears earlier in a link reference
    /// definition's label, which isn't a node in the tree, so the split
    /// lands in the label and the paragraph itself is never split.
    ref_def_label,
    /// A code span whose text spans lines can't be found verbatim (its line
    /// breaks render as spaces), so the search cursor isn't moved past it.
    /// A later paragraph's text then matches inside the code span, the split
    /// lands there, and the paragraph itself is never split.
    code_span_match,
};

/// Identifies one input: a spec example under one mutation.
const InputKey = struct { number: usize, mutation: Mutation };

/// Orders by example number, then by mutation in declaration order.
fn compareKey(key: InputKey, entry: KnownFailure) std.math.Order {
    return switch (std.math.order(key.number, entry.number)) {
        .eq => std.math.order(@intFromEnum(key.mutation), @intFromEnum(entry.mutation)),
        else => |order| order,
    };
}

// Guarantee that `entries` remains ordered.
comptime {
    if (0 < entries.len) {
        // Pair each entry with the next.
        for (entries[0 .. entries.len - 1], entries[1..]) |prev, next| {
            const in_order = compareKey(.{ .number = prev.number, .mutation = prev.mutation }, next) == .lt;
            if (!in_order) @compileError(std.fmt.comptimePrint(
                "known failures must be in strictly increasing (number, mutation) order: example {d} ({s}) is followed by example {d} ({s})",
                .{ prev.number, @tagName(prev.mutation), next.number, @tagName(next.mutation) },
            ));
        }
    }
}

pub const Found = struct {
    /// Index into `entries`.
    index: usize,
    reason: FailureReason,
};

/// The entry for example `number` under `mutation`, or null if it isn't a
/// known failure.
pub fn lookup(number: usize, mutation: Mutation) ?Found {
    // An empty `entries` can't be indexed at all, even at a runtime index,
    // so don't analyze the lookup in that case.
    if (entries.len == 0) return null;

    const key: InputKey = .{ .number = number, .mutation = mutation };
    const i = std.sort.binarySearch(KnownFailure, &entries, key, compareKey) orelse return null;
    return .{ .index = i, .reason = entries[i].reason };
}
