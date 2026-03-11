import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private enum FocusOperationEvent: Equatable {
    case activate(pid_t)
    case focus(pid_t, UInt32)
    case raise
}

private func makeFocusTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.focus-order.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeFocusTestMonitor(
    displayId: CGDirectDisplayID = 1,
    name: String = "Main",
    x: CGFloat = 0,
    y: CGFloat = 0,
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

private func makeFocusTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private final class NotificationValueBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private func makeFocusTestController(
    windowFocusOperations: WindowFocusOperations
) -> (controller: WMController, workspaceId: WorkspaceDescriptor.ID, handle: WindowHandle) {
    let settings = SettingsStore(defaults: makeFocusTestDefaults())
    let controller = WMController(settings: settings, windowFocusOperations: windowFocusOperations)
    let monitor = makeFocusTestMonitor()
    controller.workspaceManager.updateMonitors([monitor])
    controller.workspaceManager.reconcileAfterMonitorChange()

    guard let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id else {
        fatalError("Expected a visible workspace for focus test setup")
    }

    let window = makeFocusTestWindow()
    let handle = controller.workspaceManager.addWindow(window, pid: getpid(), windowId: window.windowId, to: workspaceId)
    return (controller, workspaceId, handle)
}

@Suite struct WMControllerFocusTests {
    @Test @MainActor func focusWindowPerformsActivatePrivateFocusAndRaiseInOrder() {
        var events: [FocusOperationEvent] = []
        let operations = WindowFocusOperations(
            activateApp: { pid in
                events.append(.activate(pid))
            },
            focusSpecificWindow: { pid, windowId, _ in
                events.append(.focus(pid, windowId))
            },
            raiseWindow: { _ in
                events.append(.raise)
            }
        )
        let (controller, _, handle) = makeFocusTestController(windowFocusOperations: operations)

        controller.focusWindow(handle)

        #expect(events == [
            .activate(getpid()),
            .focus(getpid(), 101),
            .raise
        ])
    }

    @Test @MainActor func focusWindowClearsNonManagedFocusAndRecordsWorkspaceMemory() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        controller.focusManager.setNonManagedFocus(active: true)

        controller.focusWindow(handle)

        #expect(controller.focusManager.isNonManagedFocusActive == false)
        #expect(controller.focusManager.lastFocusedByWorkspace[workspaceId] == handle)
    }

    @Test @MainActor func controllerFocusAccessorsReflectWorkspaceManagerOwnedState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)

        controller.focusManager.setFocus(handle, in: workspaceId)

        #expect(controller.focusedHandle == handle)
        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.lastFocusedHandle(in: workspaceId) == handle)
        #expect(controller.activeMonitorId == controller.workspaceManager.interactionMonitorId)
    }

    @Test @MainActor func focusNotificationsTrackWorkspaceManagerOwnedState() {
        let operations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
        let (controller, workspaceId, handle) = makeFocusTestController(windowFocusOperations: operations)
        let secondaryMonitor = makeFocusTestMonitor(
            displayId: 2,
            name: "Secondary",
            x: 1920
        )
        controller.workspaceManager.updateMonitors([
            makeFocusTestMonitor(),
            secondaryMonitor
        ])
        controller.workspaceManager.reconcileAfterMonitorChange()

        guard let workspace2 = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true) else {
            Issue.record("Failed to create secondary workspace")
            return
        }
        #expect(controller.workspaceManager.setActiveWorkspace(workspace2, on: secondaryMonitor.id))

        let window2 = makeFocusTestWindow(windowId: 202)
        let handle2 = controller.workspaceManager.addWindow(
            window2,
            pid: getpid(),
            windowId: window2.windowId,
            to: workspace2
        )

        let focusHandleId = NotificationValueBox<UUID?>(nil)
        let workspaceIdBox = NotificationValueBox<WorkspaceDescriptor.ID?>(nil)
        let monitorDisplayIdBox = NotificationValueBox<CGDirectDisplayID?>(nil)

        let center = NotificationCenter.default
        let focusObserver = center.addObserver(
            forName: .omniwmFocusChanged,
            object: controller,
            queue: nil
        ) { notification in
            focusHandleId.value = notification.userInfo?[OmniWMFocusNotificationKey.newHandleId] as? UUID
        }
        let workspaceObserver = center.addObserver(
            forName: .omniwmFocusedWorkspaceChanged,
            object: controller,
            queue: nil
        ) { notification in
            workspaceIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID
        }
        let monitorObserver = center.addObserver(
            forName: .omniwmFocusedMonitorChanged,
            object: controller,
            queue: nil
        ) { notification in
            monitorDisplayIdBox.value = notification.userInfo?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID
        }

        defer {
            center.removeObserver(focusObserver)
            center.removeObserver(workspaceObserver)
            center.removeObserver(monitorObserver)
        }

        controller.focusManager.setFocus(handle, in: workspaceId)
        controller.focusManager.setFocus(handle2, in: workspace2)

        #expect(focusHandleId.value == handle2.id)
        #expect(workspaceIdBox.value == workspace2)
        #expect(monitorDisplayIdBox.value == secondaryMonitor.displayId)
    }
}
