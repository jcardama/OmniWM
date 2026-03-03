import Foundation
import Testing

@testable import OmniWM

private let omniOK: Int32 = 0
private let omniErrOutOfRange: Int32 = -2

private func makeValidationFixture() -> (engine: NiriLayoutEngine, workspaceId: WorkspaceDescriptor.ID) {
    let engine = NiriLayoutEngine(maxWindowsPerColumn: 6)
    let workspaceId = WorkspaceDescriptor.ID()
    let root = NiriRoot(workspaceId: workspaceId)
    engine.roots[workspaceId] = root

    for columnIndex in 0 ..< 2 {
        let column = NiriContainer()
        if columnIndex == 1 {
            column.displayMode = .tabbed
        }
        root.appendChild(column)

        for rowIndex in 0 ..< 2 {
            let handle = makeTestHandle(pid: pid_t(20_000 + columnIndex * 10 + rowIndex))
            let window = NiriWindow(handle: handle)
            column.appendChild(window)
            engine.handleToNode[handle] = window
        }

        column.setActiveTileIdx(column.isTabbed ? 1 : 0)
    }

    return (engine, workspaceId)
}

@Suite struct NiriZigStateKernelTests {
    @Test func acceptsValidSnapshot() {
        let fixture = makeValidationFixture()
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))
        let outcome = NiriStateZigKernel.validate(snapshot: snapshot)

        #expect(outcome.isValid)
        #expect(outcome.rc == omniOK)
        #expect(outcome.result.column_count == snapshot.columns.count)
        #expect(outcome.result.window_count == snapshot.windows.count)
        #expect(outcome.result.first_invalid_column_index == -1)
        #expect(outcome.result.first_invalid_window_index == -1)
    }

    @Test func rejectsInvalidColumnRange() {
        let fixture = makeValidationFixture()
        var snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        #expect(!snapshot.columns.isEmpty)
        snapshot.columns[0].window_start = snapshot.windows.count
        snapshot.columns[0].window_count = 1

        let outcome = NiriStateZigKernel.validate(snapshot: snapshot)
        #expect(!outcome.isValid)
        #expect(outcome.rc == omniErrOutOfRange)
        #expect(outcome.result.first_invalid_column_index == 0)
        #expect(outcome.result.first_invalid_window_index == -1)
        #expect(outcome.result.first_error_code == omniErrOutOfRange)
    }

    @Test func rejectsInvalidActiveTileIndex() {
        let fixture = makeValidationFixture()
        var snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        #expect(!snapshot.columns.isEmpty)
        #expect(snapshot.columns[0].window_count > 0)
        snapshot.columns[0].active_tile_idx = snapshot.columns[0].window_count

        let outcome = NiriStateZigKernel.validate(snapshot: snapshot)
        #expect(!outcome.isValid)
        #expect(outcome.rc == omniErrOutOfRange)
        #expect(outcome.result.first_invalid_column_index == 0)
        #expect(outcome.result.first_invalid_window_index == -1)
        #expect(outcome.result.first_error_code == omniErrOutOfRange)
    }

    @Test func rejectsInvalidWindowColumnIndex() {
        let fixture = makeValidationFixture()
        var snapshot = NiriStateZigKernel.makeSnapshot(columns: fixture.engine.columns(in: fixture.workspaceId))

        #expect(!snapshot.windows.isEmpty)
        snapshot.windows[0].column_index = snapshot.columns.count

        let outcome = NiriStateZigKernel.validate(snapshot: snapshot)
        #expect(!outcome.isValid)
        #expect(outcome.rc == omniErrOutOfRange)
        #expect(outcome.result.first_invalid_column_index == -1)
        #expect(outcome.result.first_invalid_window_index == 0)
        #expect(outcome.result.first_error_code == omniErrOutOfRange)
    }

    @Test func engineHelperValidatesWorkspaceSnapshot() {
        let fixture = makeValidationFixture()
        #expect(fixture.engine.validateStateSnapshotWithZig(in: fixture.workspaceId))
    }
}
