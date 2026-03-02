import CZigLayout
import Foundation

enum NiriAxisSolver {
    struct Input {
        let weight: CGFloat
        let minConstraint: CGFloat
        let maxConstraint: CGFloat
        let hasMaxConstraint: Bool
        let isConstraintFixed: Bool
        let hasFixedValue: Bool
        let fixedValue: CGFloat?
    }

    struct Output {
        let value: CGFloat
        let wasConstrained: Bool
    }

    @inlinable
    static func solve(
        windows: [Input],
        availableSpace: CGFloat,
        gapSize: CGFloat,
        isTabbed: Bool = false
    ) -> [Output] {
        let n = windows.count
        guard n > 0 else { return [] }

        let inputs: [OmniAxisInput] = windows.map { w in
            OmniAxisInput(
                weight: Double(w.weight),
                min_constraint: Double(w.minConstraint),
                max_constraint: Double(w.maxConstraint),
                has_max_constraint: w.hasMaxConstraint ? 1 : 0,
                is_constraint_fixed: w.isConstraintFixed ? 1 : 0,
                has_fixed_value: w.hasFixedValue ? 1 : 0,
                fixed_value: Double(w.fixedValue ?? 0.0)
            )
        }

        var outputs = [OmniAxisOutput](
            repeating: OmniAxisOutput(value: 0, was_constrained: 0),
            count: n
        )

        let rc: Int32 = inputs.withUnsafeBufferPointer { inBuf in
            outputs.withUnsafeMutableBufferPointer { outBuf in
                omni_axis_solve(
                    inBuf.baseAddress,
                    n,
                    Double(availableSpace),
                    Double(gapSize),
                    isTabbed ? 1 : 0,
                    outBuf.baseAddress,
                    n
                )
            }
        }

        precondition(rc == 0, "omni_axis_solve failed with rc=\(rc)")

        return outputs.map { o in
            Output(value: CGFloat(o.value), wasConstrained: o.was_constrained != 0)
        }
    }
}
