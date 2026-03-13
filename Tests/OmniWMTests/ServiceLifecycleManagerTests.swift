import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeLifecycleTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.lifecycle.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeLifecycleMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

private func makeLifecycleWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

@Suite struct ServiceLifecycleManagerTests {
    @Test @MainActor func monitorChangeKeepsForcedWorkspaceAuthoritativeAfterRestore() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "3", monitorAssignment: .secondary)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let oldLeft = makeLifecycleMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeLifecycleMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws3 = controller.workspaceManager.workspaceId(for: "3", createIfMissing: true) else {
            Issue.record("Failed to create expected test workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws3, on: oldRight.id))

        let newLeft = makeLifecycleMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeLifecycleMonitor(displayId: 100, name: "L", x: 1920, y: 0)

        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [newLeft, newRight],
            performPostUpdateActions: false
        )

        let sorted = Monitor.sortedByPosition(controller.workspaceManager.monitors)
        guard let forcedTarget = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted) else {
            Issue.record("Failed to resolve forced monitor target")
            return
        }

        #expect(forcedTarget.id == newRight.id)
        #expect(controller.workspaceManager.activeWorkspace(on: forcedTarget.id)?.id == ws3)
        #expect(controller.workspaceManager.activeWorkspace(on: newLeft.id)?.id != ws3)
    }

    @Test @MainActor func appTerminationClearsFocusMemoryAndDeadHandlesDoNotReturn() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let monitor = makeLifecycleMonitor(displayId: 100, name: "Main", x: 0, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        let pid: pid_t = 7101
        let handle1 = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 7102),
            pid: pid,
            windowId: 7102,
            to: ws1
        )
        let handle2 = controller.workspaceManager.addWindow(
            makeLifecycleWindow(windowId: 7103),
            pid: pid,
            windowId: 7103,
            to: ws2
        )

        _ = controller.workspaceManager.setManagedFocus(handle1, in: ws1, onMonitor: monitor.id)
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: monitor.id))
        _ = controller.workspaceManager.setManagedFocus(handle2, in: ws2, onMonitor: monitor.id)

        lifecycleManager.handleAppTerminated(pid: pid)

        #expect(controller.workspaceManager.entries(forPid: pid).isEmpty)
        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.lastFocusedHandle(in: ws1) == nil)
        #expect(controller.workspaceManager.lastFocusedHandle(in: ws2) == nil)

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: monitor.id))
        #expect(controller.workspaceManager.resolveWorkspaceFocus(in: ws1) == nil)
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: monitor.id))
        #expect(controller.workspaceManager.resolveWorkspaceFocus(in: ws2) == nil)
    }

    @Test @MainActor func monitorReconnectRestorePreservesViewportState() {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)

        let oldLeft = makeLifecycleMonitor(displayId: 100, name: "L", x: 0, y: 0)
        let oldRight = makeLifecycleMonitor(displayId: 200, name: "R", x: 1920, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldLeft, oldRight])

        guard let ws1 = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
              let ws2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create expected workspaces")
            return
        }

        #expect(controller.workspaceManager.setActiveWorkspace(ws1, on: oldLeft.id))
        #expect(controller.workspaceManager.setActiveWorkspace(ws2, on: oldRight.id))

        let selectedNodeId = NodeId()
        controller.workspaceManager.withNiriViewportState(for: ws2) { state in
            state.activeColumnIndex = 3
            state.selectedNodeId = selectedNodeId
        }

        let newLeft = makeLifecycleMonitor(displayId: 200, name: "R", x: 0, y: 0)
        let newRight = makeLifecycleMonitor(displayId: 100, name: "L", x: 1920, y: 0)
        lifecycleManager.applyMonitorConfigurationChanged(
            currentMonitors: [newLeft, newRight],
            performPostUpdateActions: false
        )

        #expect(controller.workspaceManager.activeWorkspace(on: newRight.id)?.id == ws2)
        #expect(controller.workspaceManager.niriViewportState(for: ws2).activeColumnIndex == 3)
        #expect(controller.workspaceManager.niriViewportState(for: ws2).selectedNodeId == selectedNodeId)
    }

    @Test @MainActor func monitorConfigurationChangeRequestsFullRescanWhileDelegatingStateRestore() async {
        let defaults = makeLifecycleTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main)
        ]

        let controller = WMController(settings: settings)
        let lifecycleManager = ServiceLifecycleManager(controller: controller)
        let oldMonitor = makeLifecycleMonitor(displayId: 100, name: "Old", x: 0, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([oldMonitor])

        guard let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: true) else {
            Issue.record("Failed to create expected workspace")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceId, on: oldMonitor.id))

        var recordedReason: RefreshReason?
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { reason in
            recordedReason = reason
            return true
        }

        let newMonitor = makeLifecycleMonitor(displayId: 200, name: "New", x: 0, y: 0)
        lifecycleManager.applyMonitorConfigurationChanged(currentMonitors: [newMonitor])
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(recordedReason == .monitorConfigurationChanged)
        #expect(controller.workspaceManager.activeWorkspace(on: newMonitor.id)?.id == workspaceId)
    }
}
