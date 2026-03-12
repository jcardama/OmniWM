import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

func makeTestHandle(pid: pid_t = 1) -> WindowHandle {
    WindowHandle(
        id: WindowToken(pid: pid, windowId: Int.random(in: 1 ... 1_000_000)),
        pid: pid,
        axElement: AXUIElementCreateSystemWide()
    )
}

func makeTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat
) -> Monitor {
    let frame = CGRect(x: x, y: 0, width: 1920, height: 1080)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func hasNiriScrollDirective(
    _ directives: [AnimationDirective],
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    directives.contains { directive in
        if case let .startNiriScroll(candidate) = directive {
            return candidate == workspaceId
        }
        return false
    }
}

private func hasActivationDirective(
    _ directives: [AnimationDirective],
    token: WindowToken
) -> Bool {
    directives.contains { directive in
        if case let .activateWindow(candidate) = directive {
            return candidate == token
        }
        return false
    }
}

private func hasHiddenVisibilityChange(_ changes: [LayoutVisibilityChange]) -> Bool {
    changes.contains { change in
        if case .hide = change {
            return true
        }
        return false
    }
}

private func hiddenVisibilitySides(_ changes: [LayoutVisibilityChange]) -> [HideSide] {
    changes.compactMap { change in
        if case let .hide(_, side: side) = change {
            return side
        }
        return nil
    }
}

private func hasHideVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken,
    side: HideSide? = nil
) -> Bool {
    changes.contains { change in
        guard case let .hide(candidate, changeSide) = change,
              candidate == token
        else {
            return false
        }
        return side == nil || side == changeSide
    }
}

private func hasShowVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    changes.contains { change in
        if case let .show(candidate) = change {
            return candidate == token
        }
        return false
    }
}

private func hasAnyVisibilityChange(
    _ changes: [LayoutVisibilityChange],
    token: WindowToken
) -> Bool {
    hasHideVisibilityChange(changes, token: token) || hasShowVisibilityChange(changes, token: token)
}

@Suite struct NiriLayoutEngineTests {

    @Test func selectionFallbackAfterRemoval_sameSibling() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let _ = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count >= 2)

        let fallback = engine.fallbackSelectionOnRemoval(removing: w2.id, in: wsId)
        #expect(fallback != nil)
        #expect(fallback != w2.id)

        let fallbackNode = engine.findNode(by: fallback!)
        #expect(fallbackNode != nil)
    }

    @Test func selectionFallbackAfterColumnRemoval() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 3)

        let middleColIdx = 1
        var state = ViewportState()
        state.activeColumnIndex = 0

        let result = engine.animateColumnsForRemoval(
            columnIndex: middleColIdx,
            in: wsId,
            state: &state,
            gaps: 8
        )

        #expect(result.fallbackSelectionId != nil)
        let fallbackNode = engine.findNode(by: result.fallbackSelectionId!)
        #expect(fallbackNode != nil)
        #expect(result.fallbackSelectionId != w2.id)
        let isW1OrW3 = result.fallbackSelectionId == w1.id || result.fallbackSelectionId == w3.id
        #expect(isW1OrW3)
    }

    @Test func viewportOffsetAdjustsForInsertionBeforeActive() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let _ = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)

        let cols = engine.columns(in: wsId)
        #expect(cols.count == 2)

        let workingWidth: CGFloat = 1000
        let gap: CGFloat = 8
        for col in cols {
            col.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 1
        state.viewOffsetPixels = .static(0)

        let h3 = makeTestHandle()
        engine.syncWindows(
            [h3, h1, h2],
            in: wsId,
            selectedNodeId: w1.id,
            focusedHandle: nil
        )

        let colsAfter = engine.columns(in: wsId)
        #expect(colsAfter.count == 3)

        let newNode = engine.findNode(for: h3)
        #expect(newNode != nil)

        if let newCol = engine.column(of: newNode!),
           let newColIdx = engine.columnIndex(of: newCol, in: wsId)
        {
            if newColIdx <= state.activeColumnIndex {
                newCol.resolveAndCacheWidth(workingAreaWidth: workingWidth, gaps: gap)
                let shiftAmount = newCol.cachedWidth + gap
                state.viewOffsetPixels.offset(delta: Double(-shiftAmount))
                state.activeColumnIndex += 1
            }
        }

        #expect(state.viewOffsetPixels.current() < 0)
        #expect(state.activeColumnIndex == 2)
    }

    @Test func constraintApplicationRespectsBounds() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let _ = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)

        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 400, height: 300),
            maxSize: CGSize(width: 800, height: 600),
            isFixed: false
        )
        engine.updateWindowConstraints(for: h1, constraints: constraints)

        let window = engine.findNode(for: h1)!
        #expect(window.constraints == constraints)
        #expect(window.constraints.minSize.width == 400)
        #expect(window.constraints.maxSize.width == 800)
    }

    @Test func syncWindowsIdempotency() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount1 = engine.columns(in: wsId).count
        let windowIds1 = engine.root(for: wsId)!.windowIdSet

        engine.syncWindows([h1, h2, h3], in: wsId, selectedNodeId: nil)

        let colCount2 = engine.columns(in: wsId).count
        let windowIds2 = engine.root(for: wsId)!.windowIdSet

        #expect(colCount1 == colCount2)
        #expect(windowIds1 == windowIds2)
    }

    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let original = makeTestHandle(pid: 21)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        engine.syncWindows([original], in: wsId, selectedNodeId: nil)
        let originalNodeId = engine.findNode(for: original.id)?.id

        engine.syncWindows([refreshed], in: wsId, selectedNodeId: nil)

        #expect(engine.root(for: wsId)?.allWindows.count == 1)
        #expect(engine.root(for: wsId)?.windowIdSet == Set([original.id]))
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func ensureSelectionVisibleMovesViewport() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let wsId = UUID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        let w1 = engine.addWindow(handle: h1, to: wsId, afterSelection: nil)
        let w2 = engine.addWindow(handle: h2, to: wsId, afterSelection: w1.id)
        let w3 = engine.addWindow(handle: h3, to: wsId, afterSelection: w2.id)

        let workingFrame = CGRect(x: 0, y: 0, width: 500, height: 900)
        let gap: CGFloat = 8
        for col in engine.columns(in: wsId) {
            col.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gap)
        }

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        engine.ensureSelectionVisible(
            node: w3,
            in: wsId,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            alwaysCenterSingleColumn: false
        )

        #expect(state.activeColumnIndex == 2)
    }

    @Test func swapWindowHorizontalTransfersSavedWidthState() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let col1 = NiriContainer()
        let col2 = NiriContainer()
        root.appendChild(col1)
        root.appendChild(col2)

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()
        let w1 = NiriWindow(handle: h1)
        let w2 = NiriWindow(handle: h2)
        let w3 = NiriWindow(handle: h3)

        col1.appendChild(w1)
        col1.appendChild(w2)
        col2.appendChild(w3)

        engine.tokenToNode[h1.id] = w1
        engine.tokenToNode[h2.id] = w2
        engine.tokenToNode[h3.id] = w3

        col1.setActiveTileIdx(0)
        col2.setActiveTileIdx(0)

        col1.width = .proportion(0.6)
        col1.savedWidth = .proportion(0.4)
        col1.isFullWidth = true

        col2.width = .proportion(0.3)
        col2.savedWidth = nil
        col2.isFullWidth = false

        var state = ViewportState()
        let swapped = engine.swapWindow(
            w1,
            direction: .right,
            in: wsId,
            state: &state,
            workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: 8
        )

        #expect(swapped)
        #expect(col1.isFullWidth == false)
        #expect(col2.isFullWidth == true)
        #expect(col1.savedWidth == nil)
        #expect(col2.savedWidth == .proportion(0.4))
    }

    @Test func cleanupRemovedMonitorKeepsWorkspaceRootAuthoritativeForReattach() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3)
        let oldMonitor = makeTestMonitor(displayId: 100, name: "Old", x: 0)
        let newMonitor = makeTestMonitor(displayId: 200, name: "New", x: 1920)
        let wsId = UUID()

        let oldNiriMonitor = engine.ensureMonitor(for: oldMonitor.id, monitor: oldMonitor)
        let rescuedRoot = engine.ensureRoot(for: wsId)
        oldNiriMonitor.workspaceRoots[wsId] = rescuedRoot

        engine.cleanupRemovedMonitor(oldMonitor.id)
        #expect(engine.monitor(for: oldMonitor.id) == nil)
        #expect(engine.root(for: wsId) === rescuedRoot)

        engine.moveWorkspace(wsId, to: newMonitor.id, monitor: newMonitor)

        let newNiriMonitor = engine.monitor(for: newMonitor.id)
        #expect(newNiriMonitor != nil)
        #expect(newNiriMonitor?.workspaceRoots[wsId] != nil)
        if let restoredRoot = newNiriMonitor?.workspaceRoots[wsId] {
            #expect(restoredRoot === rescuedRoot)
        }
    }

    @Test func workspaceSwitchAnimationUsesSnapshotOrdering() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1)
        let monitor = makeTestMonitor(displayId: 300, name: "Main", x: 0)
        let ws1 = UUID()
        let ws2 = UUID()
        let handle1 = makeTestHandle(pid: 11)
        let handle2 = makeTestHandle(pid: 12)

        let niriMonitor = engine.ensureMonitor(for: monitor.id, monitor: monitor)
        niriMonitor.animationClock = AnimationClock()

        _ = engine.addWindow(handle: handle1, to: ws1, afterSelection: nil)
        _ = engine.addWindow(handle: handle2, to: ws2, afterSelection: nil)
        engine.moveWorkspace(ws1, to: monitor.id, monitor: monitor)
        engine.moveWorkspace(ws2, to: monitor.id, monitor: monitor)

        niriMonitor.startWorkspaceSwitch(
            orderedWorkspaceIds: [ws1, ws2],
            from: ws1,
            to: ws2
        )

        guard let time = niriMonitor.animationClock?.now() else {
            Issue.record("Expected animation clock for workspace switch test")
            return
        }
        let state = ViewportState()
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)

        let layout1 = engine.calculateCombinedLayoutWithVisibility(
            in: ws1,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )
        let layout2 = engine.calculateCombinedLayoutWithVisibility(
            in: ws2,
            monitor: monitor,
            gaps: gaps,
            state: state,
            animationTime: time
        )

        #expect(niriMonitor.workspaceSwitch?.fromWorkspaceId == ws1)
        #expect(niriMonitor.workspaceSwitch?.toWorkspaceId == ws2)
        #expect(niriMonitor.workspaceSwitch?.orderedWorkspaceIds == [ws1, ws2])
        #expect(layout1.frames[handle1.id]?.minX == 0)
        #expect((layout2.frames[handle2.id]?.minX ?? 0) > 0)
    }

    @Test @MainActor func snapshotPlanIncludesViewportPatchAndActivationForNewWindow() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri plan test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let firstToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 401)
        _ = controller.workspaceManager.setManagedFocus(firstToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let newToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 402)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan for the active workspace")
            return
        }

        #expect(plan.sessionPatch.viewportState != nil)
        #expect(plan.sessionPatch.rememberedFocusToken == newToken)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
        #expect(hasActivationDirective(plan.animationDirectives, token: newToken))
    }

    @Test @MainActor func snapshotPlanEmitsHideDiffForOffscreenWindows() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing active workspace for Niri hide-diff test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        for windowId in 501 ... 504 {
            _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .gesture(
                ViewGesture(currentViewOffset: -2500, isTrackpad: true)
            )
        }

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after viewport shift")
            return
        }

        #expect(hasHiddenVisibilityChange(plan.diff.visibilityChanges))
        #expect(!hiddenVisibilitySides(plan.diff.visibilityChanges).isEmpty)
    }

    @Test @MainActor func offscreenLeftPlaceholderFramesUseWorkingFrameOriginOnMonitorWithoutLeftNeighbor() async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 1, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 2, name: "Secondary", x: 1600, width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [primaryMonitor, secondaryMonitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id
        else {
            Issue.record("Missing active workspace for offscreen-left placeholder test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 701 ... 704 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for offscreen-left placeholder test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        let hiddenLeftTokens = tokens.filter { hiddenHandles[$0] == .left }
        #expect(!hiddenLeftTokens.isEmpty)
        for token in hiddenLeftTokens {
            #expect(frames[token]?.origin.y == workingFrame.minY)
        }
    }

    @Test func hiddenLeftRevealPreservesBottomTileHeightOnFirstVisibleFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 1)
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let leftColumn = NiriContainer()
        let rightColumn = NiriContainer()
        root.appendChild(leftColumn)
        root.appendChild(rightColumn)

        let bottomHandle = makeTestHandle(pid: 41)
        let topHandle = makeTestHandle(pid: 42)
        let visibleHandle = makeTestHandle(pid: 43)

        let bottomWindow = NiriWindow(handle: bottomHandle)
        let topWindow = NiriWindow(handle: topHandle)
        let visibleWindow = NiriWindow(handle: visibleHandle)

        bottomWindow.height = .fixed(280)
        topWindow.height = .auto(weight: 1.0)

        leftColumn.appendChild(bottomWindow)
        leftColumn.appendChild(topWindow)
        rightColumn.appendChild(visibleWindow)

        engine.tokenToNode[bottomHandle.id] = bottomWindow
        engine.tokenToNode[topHandle.id] = topWindow
        engine.tokenToNode[visibleHandle.id] = visibleWindow

        let monitor = makeLayoutPlanTestMonitor(width: 960, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var hiddenState = ViewportState()
        hiddenState.activeColumnIndex = 1
        hiddenState.viewOffsetPixels = .static(0)

        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: hiddenState,
            workingArea: area,
            animationTime: nil
        )

        #expect(hiddenLayout.hiddenHandles[bottomHandle.id] == .left)
        guard let canonicalBottomFrame = bottomWindow.frame,
              let canonicalBottomHeight = bottomWindow.resolvedHeight
        else {
            Issue.record("Expected canonical bottom window geometry after hidden layout")
            return
        }

        var revealState = hiddenState
        revealState.viewOffsetPixels = .static(-20)

        let revealLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: revealState,
            workingArea: area,
            animationTime: nil
        )

        #expect(revealLayout.hiddenHandles[bottomHandle.id] == nil)
        #expect(bottomWindow.frame == canonicalBottomFrame)
        #expect(bottomWindow.resolvedHeight == canonicalBottomHeight)
        #expect(revealLayout.frames[bottomHandle.id]?.minY == canonicalBottomFrame.minY)
        #expect(revealLayout.frames[bottomHandle.id]?.height == canonicalBottomHeight)
    }

    @Test func renderOffsetVisibilityUsesRenderedContainerFrame() {
        let engine = NiriLayoutEngine(maxWindowsPerColumn: 1, maxVisibleColumns: 1)
        engine.animationClock = AnimationClock()
        let wsId = UUID()

        let root = NiriRoot(workspaceId: wsId)
        engine.roots[wsId] = root

        let visibleColumn = NiriContainer()
        let hiddenColumn = NiriContainer()
        root.appendChild(visibleColumn)
        root.appendChild(hiddenColumn)

        let visibleHandle = makeTestHandle(pid: 51)
        let revealedHandle = makeTestHandle(pid: 52)
        let visibleWindow = NiriWindow(handle: visibleHandle)
        let revealedWindow = NiriWindow(handle: revealedHandle)

        visibleColumn.appendChild(visibleWindow)
        hiddenColumn.appendChild(revealedWindow)

        engine.tokenToNode[visibleHandle.id] = visibleWindow
        engine.tokenToNode[revealedHandle.id] = revealedWindow

        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let gaps = LayoutGaps(horizontal: 8, vertical: 8)
        let area = WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(0)

        guard let baseTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock for render-offset visibility test")
            return
        }
        let hiddenLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: baseTime
        )

        #expect(hiddenLayout.hiddenHandles[revealedHandle.id] == .right)

        hiddenColumn.animateMoveFrom(
            displacement: CGPoint(x: -40, y: 0),
            clock: engine.animationClock,
            config: engine.windowMovementAnimationConfig,
            displayRefreshRate: engine.displayRefreshRate
        )

        guard let animatedTime = engine.animationClock?.now() else {
            Issue.record("Expected animation clock after render-offset animation")
            return
        }
        let animatedLayout = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: animatedTime
        )

        let sampledOffset = hiddenColumn.renderOffset(at: animatedTime).x
        #expect(sampledOffset < -8)
        #expect((hiddenColumn.frame?.minX ?? 0) + sampledOffset < monitor.visibleFrame.maxX)
        #expect(animatedLayout.hiddenHandles[revealedHandle.id] == nil)
        #expect(animatedLayout.frames[revealedHandle.id]?.minX ?? .greatestFiniteMagnitude < monitor.visibleFrame.maxX)
    }

    @Test @MainActor func visibilityChangesOnlyEmitOnActualTransitions() async throws {
        let monitor = makeLayoutPlanTestMonitor(width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [monitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing workspace for visibility-transition test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        _ = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 911)
        let transitioningToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 912)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(20)
        }

        let seededVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard seededVisiblePlans.first != nil else {
            Issue.record("Expected visible seeding plan for visibility-transition test")
            return
        }
        controller.layoutRefreshController.executeLayoutPlans(seededVisiblePlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(0)
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let initialPlan = initialPlans.first else {
            Issue.record("Expected hidden transition plan for visibility-transition test")
            return
        }

        #expect(hasHideVisibilityChange(initialPlan.diff.visibilityChanges, token: transitioningToken, side: .right))
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        let stableHiddenPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableHiddenPlan = stableHiddenPlans.first else {
            Issue.record("Expected repeated hidden-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableHiddenPlan.diff.visibilityChanges, token: transitioningToken))

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(20)
        }

        let revealPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let revealPlan = revealPlans.first else {
            Issue.record("Expected reveal plan for visibility-transition test")
            return
        }

        #expect(hasShowVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        #expect(!hasHideVisibilityChange(revealPlan.diff.visibilityChanges, token: transitioningToken))
        controller.layoutRefreshController.executeLayoutPlans(revealPlans)

        let stableVisiblePlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        guard let stableVisiblePlan = stableVisiblePlans.first else {
            Issue.record("Expected repeated visible-state plan for visibility-transition test")
            return
        }

        #expect(!hasAnyVisibilityChange(stableVisiblePlan.diff.visibilityChanges, token: transitioningToken))
    }

    @Test @MainActor func layoutHiddenPlacementMatchesLiveHideOriginForHiddenLeftColumn() async throws {
        let primaryMonitor = makeLayoutPlanTestMonitor(displayId: 1, name: "Primary", x: 0, width: 1600, height: 900)
        let secondaryMonitor = makeLayoutPlanTestMonitor(displayId: 2, name: "Secondary", x: 1600, width: 1600, height: 900)
        let controller = makeLayoutPlanTestController(monitors: [primaryMonitor, secondaryMonitor])
        guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: primaryMonitor.id)?.id
        else {
            Issue.record("Missing workspace for hidden-placement parity test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        var tokens: [WindowToken] = []
        for windowId in 921 ... 924 {
            tokens.append(addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: windowId))
        }

        guard let engine = controller.niriEngine else {
            Issue.record("Expected Niri engine for hidden-placement parity test")
            return
        }

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.viewOffsetPixels = .static(2500)
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let workingFrame = controller.insetWorkingFrame(for: primaryMonitor)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            viewFrame: primaryMonitor.frame,
            scale: controller.layoutRefreshController.backingScale(for: primaryMonitor)
        )
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let (frames, hiddenHandles) = engine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: primaryMonitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil
        )

        guard let token = tokens.first(where: { hiddenHandles[$0] == .left }),
              let canonicalFrame = engine.findNode(for: token)?.frame,
              let hiddenFrame = frames[token],
              let liveOrigin = controller.layoutRefreshController.liveFrameHideOrigin(
                  for: canonicalFrame,
                  monitor: primaryMonitor,
                  side: .left,
                  pid: token.pid
              )
        else {
            Issue.record("Expected a hidden-left column and live hide origin for parity test")
            return
        }

        #expect(hiddenFrame.minX == liveOrigin.x)
        #expect(hiddenFrame.minY == liveOrigin.y)
    }

    @Test @MainActor func snapshotPlanUsesRemovalSeedForFallbackAndScrollParity() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            Issue.record("Missing monitor or active workspace for Niri removal-seed test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let removedToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 551)
        let survivingToken = addLayoutPlanTestWindow(on: controller, workspaceId: workspaceId, windowId: 552)
        _ = controller.workspaceManager.setManagedFocus(removedToken, in: workspaceId, onMonitor: monitor.id)

        let initialPlans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(initialPlans)

        guard let engine = controller.niriEngine,
              let removedNodeId = engine.findNode(for: removedToken)?.id
        else {
            Issue.record("Expected Niri engine state for removal-seed test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = removedNodeId
        }
        let oldFrames = engine.captureWindowFrames(in: workspaceId)
        guard !oldFrames.isEmpty else {
            Issue.record("Expected non-empty Niri frame snapshot before removal")
            return
        }

        _ = controller.workspaceManager.removeWindow(pid: removedToken.pid, windowId: removedToken.windowId)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [workspaceId],
            useScrollAnimationPath: true,
            removalSeeds: [
                workspaceId: NiriWindowRemovalSeed(
                    removedNodeId: removedNodeId,
                    oldFrames: oldFrames
                )
            ]
        )
        guard let plan = plans.first else {
            Issue.record("Expected a Niri layout plan after removal")
            return
        }
        guard let survivingNodeId = engine.findNode(for: survivingToken)?.id else {
            Issue.record("Expected surviving node after Niri removal")
            return
        }

        #expect(!plan.diff.frameChanges.contains(where: { $0.token == removedToken }))
        #expect(
            plan.diff.frameChanges.contains(where: { $0.token == survivingToken }) ||
                hasAnyVisibilityChange(plan.diff.visibilityChanges, token: survivingToken)
        )
        #expect(plan.sessionPatch.rememberedFocusToken == survivingToken)
        #expect(plan.sessionPatch.viewportState?.selectedNodeId == survivingNodeId)
        #expect(hasNiriScrollDirective(plan.animationDirectives, workspaceId: workspaceId))
    }

    @Test @MainActor func nonFocusedWorkspacePlanDoesNotClearFocusedBorder() async throws {
        let fixture = makeTwoMonitorLayoutPlanTestController()
        let controller = fixture.controller
        controller.setBordersEnabled(true)
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let primaryToken = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.primaryWorkspaceId,
            windowId: 601
        )
        _ = addLayoutPlanTestWindow(
            on: controller,
            workspaceId: fixture.secondaryWorkspaceId,
            windowId: 602
        )
        _ = controller.workspaceManager.setManagedFocus(
            primaryToken,
            in: fixture.primaryWorkspaceId,
            onMonitor: fixture.primaryMonitor.id
        )

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [fixture.primaryWorkspaceId, fixture.secondaryWorkspaceId],
            useScrollAnimationPath: true
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        #expect(lastAppliedBorderWindowIdForLayoutPlanTests(on: controller) == 601)
    }

    @Test @MainActor func staleScrollAnimationStopsBeforeRestoringInactiveWorkspaceWindows() async throws {
        let controller = makeLayoutPlanTestController()
        guard let monitor = controller.workspaceManager.monitors.first,
              let originalWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let replacementWorkspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        else {
            Issue.record("Missing monitor or workspaces for stale Niri animation test")
            return
        }

        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await waitForLayoutPlanRefreshWork(on: controller)
        controller.syncMonitorsToNiriEngine()

        let token = addLayoutPlanTestWindow(on: controller, workspaceId: originalWorkspaceId, windowId: 603)
        _ = controller.workspaceManager.setManagedFocus(token, in: originalWorkspaceId, onMonitor: monitor.id)

        let plans = try await controller.niriLayoutHandler.layoutWithNiriEngine(
            activeWorkspaces: [originalWorkspaceId]
        )
        controller.layoutRefreshController.executeLayoutPlans(plans)

        setWorkspaceInactiveHiddenStateForLayoutPlanTests(on: controller, token: token, monitor: monitor)
        controller.layoutRefreshController.stopAllScrollAnimations()
        #expect(controller.niriLayoutHandler.registerScrollAnimation(originalWorkspaceId, on: monitor.displayId))
        _ = controller.workspaceManager.setActiveWorkspace(replacementWorkspaceId, on: monitor.id)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: monitor.displayId)

        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(controller.workspaceManager.hiddenState(for: token)?.workspaceInactive == true)
    }
}
