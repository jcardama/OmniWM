import Foundation

@MainActor
final class FocusManager {
    private let workspaceManager: WorkspaceManager

    var focusedHandle: WindowHandle? { workspaceManager.focusedHandle }
    var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowHandle] { workspaceManager.lastFocusedByWorkspace }
    var isNonManagedFocusActive: Bool { workspaceManager.isNonManagedFocusActive }
    var isAppFullscreenActive: Bool { workspaceManager.isAppFullscreenActive }

    private var pendingFocusHandle: WindowHandle?
    private var deferredFocusHandle: WindowHandle?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    var onFocusedHandleChanged: ((WindowHandle?) -> Void)?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func setNonManagedFocus(active: Bool) {
        workspaceManager.setNonManagedFocus(active: active)
    }

    func setAppFullscreen(active: Bool) {
        workspaceManager.setAppFullscreen(active: active)
    }

    func setFocus(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) {
        _ = workspaceManager.setFocusedHandle(handle, in: workspaceId)
        onFocusedHandleChanged?(handle)
    }

    func clearFocus() {
        if workspaceManager.clearFocus() {
            onFocusedHandleChanged?(nil)
        }
    }

    func updateWorkspaceFocusMemory(_ handle: WindowHandle, for workspaceId: WorkspaceDescriptor.ID) {
        _ = workspaceManager.rememberFocus(handle, in: workspaceId)
    }

    func clearWorkspaceFocusMemory(for workspaceId: WorkspaceDescriptor.ID) {
        _ = workspaceManager.clearLastFocusedHandle(in: workspaceId)
    }

    func resolveWorkspaceFocus(
        for workspaceId: WorkspaceDescriptor.ID,
        entries: [WindowModel.Entry]
    ) -> WindowHandle? {
        workspaceManager.lastFocusedHandle(in: workspaceId) ?? entries.first?.handle
    }

    @discardableResult
    func resolveAndSetWorkspaceFocus(
        for workspaceId: WorkspaceDescriptor.ID,
        entries: [WindowModel.Entry]
    ) -> WindowHandle? {
        if let handle = resolveWorkspaceFocus(for: workspaceId, entries: entries) {
            setFocus(handle, in: workspaceId)
            return handle
        } else {
            clearFocus()
            return nil
        }
    }

    func recoverSourceFocusAfterMove(
        in workspaceId: WorkspaceDescriptor.ID,
        preferredNodeId: NodeId?,
        engine: NiriLayoutEngine?,
        entries: [WindowModel.Entry]
    ) {
        if let engine,
           let preferredId = preferredNodeId,
           let node = engine.findNode(by: preferredId) as? NiriWindow
        {
            setFocus(node.handle, in: workspaceId)
        } else if let fallback = entries.first?.handle {
            setFocus(fallback, in: workspaceId)
        } else {
            clearFocus()
        }
    }

    func handleWindowRemoved(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID?) {
        if pendingFocusHandle?.id == handle.id {
            pendingFocusHandle = nil
        }
        if deferredFocusHandle?.id == handle.id {
            deferredFocusHandle = nil
        }
        let wasFocused = workspaceManager.focusedHandle?.id == handle.id
        workspaceManager.handleWindowRemoved(handle, in: workspaceId)
        if wasFocused {
            onFocusedHandleChanged?(nil)
        }
    }

    func focusWindow(
        _ handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
        performFocus: () -> Void,
        onDeferredFocus: @escaping (WindowHandle) -> Void
    ) {
        let now = Date()

        if pendingFocusHandle == handle {
            if now.timeIntervalSince(lastFocusTime) < 0.016 {
                return
            }
        }

        if isFocusOperationPending {
            deferredFocusHandle = handle
            return
        }

        isFocusOperationPending = true
        pendingFocusHandle = handle
        lastFocusTime = now
        _ = workspaceManager.rememberFocus(handle, in: workspaceId)

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusHandle, deferred != handle {
            deferredFocusHandle = nil
            onDeferredFocus(deferred)
        }
    }

    func ensureFocusedHandleValid(
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine?,
        workspaceManager: WorkspaceManager,
        focusWindowAction: (WindowHandle) -> Void
    ) {
        if let focused = self.workspaceManager.focusedHandle,
           workspaceManager.entry(for: focused)?.workspaceId == workspaceId
        {
            _ = self.workspaceManager.rememberFocus(focused, in: workspaceId)
            if let engine,
               let node = engine.findNode(for: focused)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            return
        }

        if let remembered = self.workspaceManager.lastFocusedHandle(in: workspaceId),
           workspaceManager.entry(for: remembered) != nil
        {
            setFocus(remembered, in: workspaceId)
            if let engine,
               let node = engine.findNode(for: remembered)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            focusWindowAction(remembered)
            return
        }

        let newHandle = workspaceManager.entries(in: workspaceId).first?.handle
        if let newHandle {
            setFocus(newHandle, in: workspaceId)
            if let engine,
               let node = engine.findNode(for: newHandle)
            {
                workspaceManager.setSelection(node.id, for: workspaceId)
            }
            focusWindowAction(newHandle)
        } else {
            clearFocus()
        }
    }
}
