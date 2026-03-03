import CZigLayout
import Foundation

enum NiriStateZigKernel {
    struct Snapshot {
        var columns: [OmniNiriStateColumnInput]
        var windows: [OmniNiriStateWindowInput]
    }

    struct ValidationOutcome {
        let rc: Int32
        let result: OmniNiriStateValidationResult

        var isValid: Bool {
            rc == OMNI_OK && result.first_error_code == OMNI_OK
        }
    }

    private static func omniUUID(from nodeId: NodeId) -> OmniUuid128 {
        omniUUID(from: nodeId.uuid)
    }

    private static func omniUUID(from uuid: UUID) -> OmniUuid128 {
        var rawUUID = uuid.uuid
        var encoded = OmniUuid128()
        withUnsafeBytes(of: &rawUUID) { src in
            withUnsafeMutableBytes(of: &encoded) { dst in
                dst.copyBytes(from: src)
            }
        }
        return encoded
    }

    static func makeSnapshot(columns: [NiriContainer]) -> Snapshot {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var columnInputs: [OmniNiriStateColumnInput] = []
        columnInputs.reserveCapacity(columns.count)

        var windowInputs: [OmniNiriStateWindowInput] = []
        windowInputs.reserveCapacity(estimatedWindowCount)

        for (columnIndex, column) in columns.enumerated() {
            let start = windowInputs.count
            let windows = column.windowNodes
            let columnId = omniUUID(from: column.id)

            for window in windows {
                windowInputs.append(
                    OmniNiriStateWindowInput(
                        window_id: omniUUID(from: window.id),
                        column_id: columnId,
                        column_index: columnIndex
                    )
                )
            }

            columnInputs.append(
                OmniNiriStateColumnInput(
                    column_id: columnId,
                    window_start: start,
                    window_count: windows.count,
                    active_tile_idx: max(0, column.activeTileIdx),
                    is_tabbed: column.isTabbed ? 1 : 0
                )
            )
        }

        return Snapshot(columns: columnInputs, windows: windowInputs)
    }

    static func validate(snapshot: Snapshot) -> ValidationOutcome {
        var rawResult = OmniNiriStateValidationResult(
            column_count: 0,
            window_count: 0,
            first_invalid_column_index: -1,
            first_invalid_window_index: -1,
            first_error_code: Int32(OMNI_OK)
        )

        let rc: Int32 = snapshot.columns.withUnsafeBufferPointer { columnBuf in
            snapshot.windows.withUnsafeBufferPointer { windowBuf in
                withUnsafeMutablePointer(to: &rawResult) { resultPtr in
                    omni_niri_validate_state_snapshot(
                        columnBuf.baseAddress,
                        columnBuf.count,
                        windowBuf.baseAddress,
                        windowBuf.count,
                        resultPtr
                    )
                }
            }
        }

        return ValidationOutcome(rc: rc, result: rawResult)
    }
}
