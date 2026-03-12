import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMouseEventTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.mouse-event.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeMouseEventTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

@MainActor
private func makeMouseEventTestController() -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let controller = WMController(
        settings: SettingsStore(defaults: makeMouseEventTestDefaults()),
        windowFocusOperations: operations
    )
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    return controller
}

@MainActor
private func prepareMouseResizeFixture() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    handle: WindowHandle,
    workspaceId: WorkspaceDescriptor.ID,
    nodeId: NodeId,
    nodeFrame: CGRect,
    location: CGPoint
) {
    let controller = makeMouseEventTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.activeWorkspace()?.id else {
        fatalError("Missing active workspace for mouse fixture")
    }

    let token = controller.workspaceManager.addWindow(
        makeMouseEventTestWindow(windowId: 901),
        pid: getpid(),
        windowId: 901,
        to: workspaceId
    )
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Missing bridge handle for mouse fixture")
    }
    _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)

    guard let engine = controller.niriEngine else {
        fatalError("Missing Niri engine for mouse fixture")
    }

    let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
    _ = engine.syncWindows(
        handles,
        in: workspaceId,
        selectedNodeId: nil,
        focusedHandle: handle
    )

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    guard let node = engine.findNode(for: handle),
          let nodeFrame = node.frame,
          let monitor = controller.workspaceManager.monitor(for: workspaceId)
    else {
        fatalError("Failed to prepare interactive resize fixture")
    }

    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.selectedNodeId = node.id
    }

    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    return (controller, controller.mouseEventHandler, handle, workspaceId, node.id, nodeFrame, location)
}

@Suite struct MouseEventHandlerTests {
    @Test @MainActor func lockedInputHandlersAreNoOps() async {
        let controller = makeMouseEventTestController()
        controller.isLockScreenActive = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let handler = controller.mouseEventHandler
        handler.dispatchMouseMoved(at: CGPoint(x: 50, y: 50))
        handler.dispatchMouseDown(at: CGPoint(x: 50, y: 50), modifiers: [])
        handler.dispatchMouseDragged(at: CGPoint(x: 60, y: 60))
        handler.dispatchMouseUp(at: CGPoint(x: 60, y: 60))
        handler.dispatchScrollWheel(
            at: CGPoint(x: 50, y: 50),
            deltaX: 0,
            deltaY: 12,
            momentumPhase: 0,
            phase: 0,
            modifiers: []
        )

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }
        handler.dispatchGestureEvent(from: cgEvent)

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(handler.state.isMoving == false)
        #expect(handler.state.isResizing == false)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func resizeEndUsesInteractiveGestureImmediateRelayout() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        fixture.controller.layoutRefreshController.resetDebugState()
        fixture.controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        fixture.handler.dispatchMouseUp(at: fixture.location)
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutEvents.map(\.0) == [.interactiveGesture])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedMouseMovesCollapseToLatestLocation() async {
        let fixture = await prepareMouseResizeFixture()

        let center = CGPoint(x: fixture.nodeFrame.midX, y: fixture.nodeFrame.midY)
        let rightEdge = CGPoint(x: fixture.nodeFrame.maxX - 1, y: fixture.nodeFrame.midY)

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseMoved(at: center)
        fixture.handler.receiveTapMouseMoved(at: rightEdge)
        fixture.handler.flushPendingTapEventsForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(fixture.handler.state.currentHoveredEdges == [.right])
    }

    @Test @MainActor func queuedResizeDragFlushesBeforeMouseUpUsingLatestLocation() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId),
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state")
            return
        }

        let originalWidth = column.cachedWidth
        let insetFrame = fixture.controller.insetWorkingFrame(for: monitor)
        let maxWidth = insetFrame.width - CGFloat(fixture.controller.workspaceManager.gaps)
        let expectedWidth = min(originalWidth + 24, maxWidth)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true
        fixture.handler.resetDebugStateForTests()

        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 8, y: fixture.location.y)
        )
        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(debugSnapshot.flushedBeforeImmediateDispatch == 1)
        #expect(abs(column.cachedWidth - expectedWidth) < 0.001)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func scrollBurstOnlyMergesWithinMatchingModifierAndPhaseGroups() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        handler.resetDebugStateForTests()
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 4,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 6,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 8,
            momentumPhase: 1,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.flushPendingTapEventsForTests()

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 3)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainRuns == 2)
        #expect(debugSnapshot.drainedTransientEvents == 2)
    }
}
