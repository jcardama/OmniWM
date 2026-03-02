#pragma once
#include <stddef.h>
#include <stdint.h>

/// Input descriptor for one window on a single axis.
/// Zig struct OmniAxisInput must match this layout exactly.
typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    double fixed_value; // ignored when has_fixed_value == 0
} OmniAxisInput;

/// Result for one window on a single axis.
typedef struct {
    double value;
    uint8_t was_constrained;
} OmniAxisOutput;

/// Solve axis layout for window_count windows.
///
/// is_tabbed: 0 = normal (weighted) layout, 1 = tabbed (all windows share one span).
///
/// Returns 0 on success.
/// Returns -1 if out_count < window_count or window_count exceeds the internal limit.
int32_t omni_axis_solve(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    OmniAxisOutput *out,
    size_t out_count);

/// Tabbed variant (all windows get the same span, gaps are ignored).
/// Equivalent to calling omni_axis_solve with is_tabbed = 1.
int32_t omni_axis_solve_tabbed(
    const OmniAxisInput *windows,
    size_t window_count,
    double available_space,
    double gap_size,
    OmniAxisOutput *out,
    size_t out_count);
