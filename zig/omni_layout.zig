/// omni_layout.zig — Zig port of NiriAxisSolver
///
/// Matches NiriConstraintSolver.swift exactly so that Swift can delegate
/// the hot path to this compiled static library while keeping the Swift
/// reference implementation around for correctness assertions.

const std = @import("std");

// ──────────────────────────────────────────────────────────────────────────────
// ABI types (must match omni_layout.h exactly)
// ──────────────────────────────────────────────────────────────────────────────

pub const OmniAxisInput = extern struct {
    weight: f64,
    min_constraint: f64,
    max_constraint: f64,
    has_max_constraint: u8,
    is_constraint_fixed: u8,
    has_fixed_value: u8,
    fixed_value: f64, // ignored when has_fixed_value == 0
};

pub const OmniAxisOutput = extern struct {
    value: f64,
    was_constrained: u8,
};

// Stack-buffer cap — realistic window counts are < 50; 512 is a safe ceiling.
const MAX_WINDOWS = 512;

// ──────────────────────────────────────────────────────────────────────────────
// Exported entry points
// ──────────────────────────────────────────────────────────────────────────────

/// Solve axis layout for `window_count` windows.
/// Returns 0 on success, -1 when out_count < window_count or window_count
/// exceeds the internal stack limit.
export fn omni_axis_solve(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    is_tabbed: u8,
    out: [*]OmniAxisOutput,
    out_count: usize,
) i32 {
    if (out_count < window_count) return -1;
    if (window_count == 0) return 0;
    if (window_count > MAX_WINDOWS) return -1;

    if (is_tabbed != 0) {
        return omni_axis_solve_tabbed(windows, window_count, available_space, gap_size, out, out_count);
    }

    solveNormal(windows, window_count, available_space, gap_size, out);
    return 0;
}

/// Tabbed variant: every window in the container shares the same span.
export fn omni_axis_solve_tabbed(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    out: [*]OmniAxisOutput,
    out_count: usize,
) i32 {
    _ = gap_size; // tabbed layout ignores gaps
    if (out_count < window_count) return -1;
    if (window_count == 0) return 0;

    solveTabbedImpl(windows, window_count, available_space, out);
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// Internal implementations
// ──────────────────────────────────────────────────────────────────────────────

/// Ports `NiriAxisSolver.solve()` (the non-tabbed branch).
fn solveNormal(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    gap_size: f64,
    out: [*]OmniAxisOutput,
) void {
    const n = window_count;

    // Total gap space between n windows
    const gap_count: f64 = @floatFromInt(if (n > 0) n - 1 else 0);
    const total_gaps = gap_size * gap_count;
    const space_for_windows = available_space - total_gaps;

    // If there is no usable space every window falls back to its minimum.
    if (space_for_windows <= 0) {
        for (0..n) |i| {
            out[i] = .{ .value = windows[i].min_constraint, .was_constrained = 1 };
        }
        return;
    }

    // Working buffers on the stack
    var values: [MAX_WINDOWS]f64 = undefined;
    var is_fixed: [MAX_WINDOWS]bool = undefined;
    var used_space: f64 = 0.0;

    for (0..n) |i| {
        values[i] = 0.0;
        is_fixed[i] = false;
    }

    // Pass 1 — pin windows that already have a known size
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_fixed_value != 0) {
            // Clamp fixed value to [min, max]
            var clamped = w.fixed_value;
            clamped = @max(clamped, w.min_constraint);
            if (w.has_max_constraint != 0) clamped = @min(clamped, w.max_constraint);
            values[i] = clamped;
            is_fixed[i] = true;
            used_space += clamped;
        } else if (w.is_constraint_fixed != 0) {
            values[i] = w.min_constraint;
            is_fixed[i] = true;
            used_space += values[i];
        }
    }

    // Pass 2 — iteratively distribute remaining space by weight, fixing any
    //           window that would violate its minimum constraint.
    const max_iterations = n + 1;
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        const remaining_space = space_for_windows - used_space;

        var total_weight: f64 = 0.0;
        for (0..n) |i| {
            if (!is_fixed[i]) total_weight += windows[i].weight;
        }

        if (total_weight <= 0.0) break;

        // Find the first window whose proportional allocation is below its min.
        var any_violation = false;
        for (0..n) |i| {
            if (is_fixed[i]) continue;
            const proposed = remaining_space * (windows[i].weight / total_weight);
            if (proposed < windows[i].min_constraint) {
                values[i] = windows[i].min_constraint;
                is_fixed[i] = true;
                used_space += windows[i].min_constraint;
                any_violation = true;
                break; // restart with updated used_space
            }
        }

        if (!any_violation) {
            // No violations: assign final proportional values and stop.
            for (0..n) |i| {
                if (!is_fixed[i]) {
                    values[i] = remaining_space * (windows[i].weight / total_weight);
                }
            }
            break;
        }
    }

    // Pass 3 — cap windows that exceed their maximum constraint and redistribute
    //           the freed excess to unconstrained windows.
    var excess_space: f64 = 0.0;
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_max_constraint != 0 and values[i] > w.max_constraint) {
            excess_space += values[i] - w.max_constraint;
            values[i] = w.max_constraint;
            is_fixed[i] = true;
        }
    }

    if (excess_space > 0.0) {
        var remaining_weight: f64 = 0.0;
        for (0..n) |i| {
            if (!is_fixed[i]) remaining_weight += windows[i].weight;
        }
        if (remaining_weight > 0.0) {
            for (0..n) |i| {
                if (!is_fixed[i]) {
                    values[i] += excess_space * (windows[i].weight / remaining_weight);
                }
            }
        }
    }

    // Build output — wasConstrained iff the window was pinned at a constraint edge.
    for (0..n) |i| {
        const w = windows[i];
        const was_constrained = is_fixed[i] and
            (values[i] == w.min_constraint or values[i] == w.max_constraint);
        out[i] = .{
            .value = @max(1.0, values[i]),
            .was_constrained = @intFromBool(was_constrained),
        };
    }
}

/// Ports `NiriAxisSolver.solveTabbed()`.
/// All windows receive the same span value.
fn solveTabbedImpl(
    windows: [*]const OmniAxisInput,
    window_count: usize,
    available_space: f64,
    out: [*]OmniAxisOutput,
) void {
    const n = window_count;

    // Maximum of all minimum constraints (Swift: .max() ?? 1 — but ?? 1 only
    // fires for empty arrays which we've already handled above).
    var max_min_constraint: f64 = 0.0;
    for (0..n) |i| {
        max_min_constraint = @max(max_min_constraint, windows[i].min_constraint);
    }

    // First fixed value, if any window carries one.
    var fixed_value: ?f64 = null;
    for (0..n) |i| {
        if (windows[i].has_fixed_value != 0) {
            fixed_value = windows[i].fixed_value;
            break;
        }
    }

    var shared_value: f64 = if (fixed_value) |fv|
        @max(fv, max_min_constraint)
    else
        @max(available_space, max_min_constraint);

    // Apply the tightest maximum constraint across all windows.
    var min_max_constraint: ?f64 = null;
    for (0..n) |i| {
        const w = windows[i];
        if (w.has_max_constraint != 0) {
            if (min_max_constraint == null or w.max_constraint < min_max_constraint.?) {
                min_max_constraint = w.max_constraint;
            }
        }
    }
    if (min_max_constraint) |mc| {
        shared_value = @min(shared_value, mc);
    }

    shared_value = @max(1.0, shared_value);

    for (0..n) |i| {
        const w = windows[i];
        const was_constrained = shared_value == w.min_constraint or
            (w.has_max_constraint != 0 and shared_value == w.max_constraint);
        out[i] = .{
            .value = shared_value,
            .was_constrained = @intFromBool(was_constrained),
        };
    }
}
