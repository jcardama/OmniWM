import ApplicationServices
import CZigLayout
import Foundation
import XCTest

@testable import OmniWM

@MainActor
final class NiriTxnIntegrationTests: XCTestCase {
    private func makeWindow() -> NiriWindow {
        let pid = getpid()
        let handle = WindowHandle(
            id: UUID(),
            pid: pid,
            axElement: AXUIElementCreateApplication(pid)
        )
        return NiriWindow(handle: handle)
    }

    func testNavigationTxnUpdatesActiveTileAndExportsDelta() throws {
        let workspace = WorkspaceDescriptor(name: "txn-nav")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)

        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        column.appendChild(firstWindow)
        column.appendChild(secondWindow)
        column.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let selection = try XCTUnwrap(
            NiriStateZigKernel.makeSelectionContext(node: firstWindow, snapshot: snapshot)
        )
        let request = NiriStateZigKernel.NavigationRequest(
            op: .focusWindowBottom,
            selection: selection
        )

        let outcome = NiriStateZigKernel.applyNavigation(
            context: context,
            request: .init(request: request, snapshot: snapshot)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertNotNil(outcome.delta)
        XCTAssertEqual(outcome.targetWindowId, secondWindow.id)
        XCTAssertEqual(outcome.delta?.columns.first?.column.activeTileIdx, 1)
    }

    func testMutationTxnExportsTargetAndDeltaCounts() throws {
        let workspace = WorkspaceDescriptor(name: "txn-mutation")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let firstColumn = try XCTUnwrap(root.columns.first)

        let leftWindow = makeWindow()
        let rightWindow = makeWindow()
        firstColumn.appendChild(leftWindow)

        let secondColumn = NiriContainer()
        root.appendChild(secondColumn)
        secondColumn.appendChild(rightWindow)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let sourceWindowIndex = try XCTUnwrap(snapshot.windowIndexByNodeId[leftWindow.id])
        let request = NiriStateZigKernel.MutationRequest(
            op: .moveWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: .right,
            maxWindowsPerColumn: engine.maxWindowsPerColumn
        )

        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request, snapshot: snapshot)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.targetWindowId)
        XCTAssertGreaterThanOrEqual(outcome.delta?.columns.count ?? 0, 1)
        XCTAssertLessThanOrEqual(outcome.delta?.columns.count ?? 0, snapshot.columns.count)
        XCTAssertEqual(outcome.delta?.windows.count, snapshot.windows.count)
    }

    func testCreateColumnAndMoveTxnAppliesAndReindexesMovedWindow() throws {
        let workspace = WorkspaceDescriptor(name: "txn-create-column")
        let engine = NiriLayoutEngine(maxVisibleColumns: 3)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)

        let movingWindow = makeWindow()
        let remainingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)
        sourceColumn.appendChild(remainingWindow)
        sourceColumn.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let sourceWindowIndex = try XCTUnwrap(snapshot.windowIndexByNodeId[movingWindow.id])
        let request = NiriStateZigKernel.MutationRequest(
            op: .createColumnAndMove,
            sourceWindowIndex: sourceWindowIndex,
            direction: .right,
            maxVisibleColumns: engine.maxVisibleColumns
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                snapshot: snapshot,
                createdColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        let delta = try XCTUnwrap(outcome.delta)

        let movedRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == movingWindow.id })
        let remainingRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == remainingWindow.id })
        XCTAssertEqual(movedRecord.columnOrderIndex, 1)
        XCTAssertEqual(remainingRecord.columnOrderIndex, 0)
    }

    func testSwapWindowHorizontalTxnRecomputesWindowColumnMetadata() throws {
        let workspace = WorkspaceDescriptor(name: "txn-swap-horizontal")
        let engine = NiriLayoutEngine(infiniteLoop: false)
        let root = engine.ensureRoot(for: workspace.id)
        let sourceColumn = try XCTUnwrap(root.columns.first)

        let sourceActiveWindow = makeWindow()
        let sourceSecondaryWindow = makeWindow()
        sourceColumn.appendChild(sourceActiveWindow)
        sourceColumn.appendChild(sourceSecondaryWindow)
        sourceColumn.setActiveTileIdx(0)

        let targetColumn = NiriContainer()
        root.appendChild(targetColumn)
        let targetActiveWindow = makeWindow()
        targetColumn.appendChild(targetActiveWindow)
        targetColumn.setActiveTileIdx(0)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(engine.ensureLayoutContext(for: workspace.id))
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: context, snapshot: snapshot),
            Int32(OMNI_OK)
        )

        let sourceWindowIndex = try XCTUnwrap(snapshot.windowIndexByNodeId[sourceActiveWindow.id])
        let request = NiriStateZigKernel.MutationRequest(
            op: .swapWindowHorizontal,
            sourceWindowIndex: sourceWindowIndex,
            direction: .right,
            infiniteLoop: false
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(request: request, snapshot: snapshot)
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        let delta = try XCTUnwrap(outcome.delta)

        let movedSourceRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == sourceActiveWindow.id })
        let movedTargetRecord = try XCTUnwrap(delta.windows.first { $0.window.windowId == targetActiveWindow.id })

        XCTAssertEqual(movedSourceRecord.columnOrderIndex, 1)
        XCTAssertEqual(movedTargetRecord.columnOrderIndex, 0)
    }

    func testWorkspaceTxnMutatesBothContextsAndExportsBothDeltas() throws {
        let sourceWorkspace = WorkspaceDescriptor(name: "txn-source")
        let targetWorkspace = WorkspaceDescriptor(name: "txn-target")
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3, infiniteLoop: false)

        let sourceRoot = engine.ensureRoot(for: sourceWorkspace.id)
        let sourceColumn = try XCTUnwrap(sourceRoot.columns.first)
        let movingWindow = makeWindow()
        sourceColumn.appendChild(movingWindow)

        let targetRoot = engine.ensureRoot(for: targetWorkspace.id)
        XCTAssertEqual(targetRoot.allWindows.count, 0)

        let sourceSnapshot = NiriStateZigKernel.makeSnapshot(columns: sourceRoot.columns)
        let targetSnapshot = NiriStateZigKernel.makeSnapshot(columns: targetRoot.columns)
        let sourceContext = try XCTUnwrap(engine.ensureLayoutContext(for: sourceWorkspace.id))
        let targetContext = try XCTUnwrap(engine.ensureLayoutContext(for: targetWorkspace.id))

        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: sourceContext, snapshot: sourceSnapshot),
            Int32(OMNI_OK)
        )
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(context: targetContext, snapshot: targetSnapshot),
            Int32(OMNI_OK)
        )

        let sourceWindowIndex = try XCTUnwrap(sourceSnapshot.windowIndexByNodeId[movingWindow.id])
        let request = NiriStateZigKernel.WorkspaceRequest(
            op: .moveWindowToWorkspace,
            sourceWindowIndex: sourceWindowIndex,
            maxVisibleColumns: engine.maxVisibleColumns
        )

        let outcome = NiriStateZigKernel.applyWorkspace(
            sourceContext: sourceContext,
            targetContext: targetContext,
            request: .init(
                request: request,
                sourceSnapshot: sourceSnapshot,
                targetCreatedColumnId: UUID(),
                sourcePlaceholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_OK))
        XCTAssertTrue(outcome.applied)
        XCTAssertNotNil(outcome.sourceDelta)
        XCTAssertNotNil(outcome.targetDelta)
        XCTAssertEqual(outcome.sourceDelta?.windows.count, 0)
        XCTAssertEqual(outcome.targetDelta?.windows.count, 1)
        XCTAssertNotNil(outcome.movedWindowId)
    }

    func testMutationTxnFailsClosedForMissingRuntimeIds() throws {
        let workspace = WorkspaceDescriptor(name: "txn-invalid")
        let engine = NiriLayoutEngine()
        let root = engine.ensureRoot(for: workspace.id)
        let column = try XCTUnwrap(root.columns.first)
        let window = makeWindow()
        column.appendChild(window)

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: engine.columns(in: workspace.id))
        let context = try XCTUnwrap(NiriLayoutZigKernel.LayoutContext())
        XCTAssertEqual(
            NiriStateZigKernel.seedRuntimeState(
                context: context,
                export: NiriStateZigKernel.RuntimeStateExport(columns: [], windows: [])
            ),
            Int32(OMNI_OK)
        )

        let sourceWindowIndex = try XCTUnwrap(snapshot.windowIndexByNodeId[window.id])
        let request = NiriStateZigKernel.MutationRequest(
            op: .removeWindow,
            sourceWindowIndex: sourceWindowIndex
        )
        let outcome = NiriStateZigKernel.applyMutation(
            context: context,
            request: .init(
                request: request,
                snapshot: snapshot,
                placeholderColumnId: UUID()
            )
        )

        XCTAssertEqual(outcome.rc, Int32(OMNI_ERR_OUT_OF_RANGE))
        XCTAssertFalse(outcome.applied)
        XCTAssertNil(outcome.delta)

        let exported = NiriStateZigKernel.exportDelta(context: context)
        XCTAssertEqual(exported.rc, Int32(OMNI_OK))
        XCTAssertEqual(exported.export.columns.count, 0)
        XCTAssertEqual(exported.export.windows.count, 0)
    }
}
