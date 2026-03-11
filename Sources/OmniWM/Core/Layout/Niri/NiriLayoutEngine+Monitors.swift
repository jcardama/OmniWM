import AppKit
import Foundation

extension NiriLayoutEngine {
    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        monitors.removeValue(forKey: monitorId)
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        monitors[monitorId]?.resolvedSettings = settings
    }

    func effectiveMaxVisibleColumns(for monitorId: Monitor.ID) -> Int {
        monitors[monitorId]?.resolvedSettings?.maxVisibleColumns ?? maxVisibleColumns
    }

    func effectiveMaxWindowsPerColumn(for monitorId: Monitor.ID) -> Int {
        monitors[monitorId]?.resolvedSettings?.maxWindowsPerColumn ?? maxWindowsPerColumn
    }

    func effectiveCenterFocusedColumn(for monitorId: Monitor.ID) -> CenterFocusedColumn {
        monitors[monitorId]?.resolvedSettings?.centerFocusedColumn ?? centerFocusedColumn
    }

    func effectiveAlwaysCenterSingleColumn(for monitorId: Monitor.ID) -> Bool {
        monitors[monitorId]?.resolvedSettings?.alwaysCenterSingleColumn ?? alwaysCenterSingleColumn
    }

    func effectiveInfiniteLoop(for monitorId: Monitor.ID) -> Bool {
        monitors[monitorId]?.resolvedSettings?.infiniteLoop ?? infiniteLoop
    }

    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           currentMonitorId == monitorId
        {
            return
        }

        if let currentMonitorId = monitorContaining(workspace: workspaceId),
           let currentMonitor = monitors[currentMonitorId]
        {
            if let root = currentMonitor.workspaceRoots.removeValue(forKey: workspaceId) {
                targetMonitor.workspaceRoots[workspaceId] = root
                roots[workspaceId] = root
            }
        }

        if targetMonitor.workspaceRoots[workspaceId] == nil {
            let root = ensureRoot(for: workspaceId)
            targetMonitor.workspaceRoots[workspaceId] = root
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        for (monitorId, niriMonitor) in monitors {
            if niriMonitor.containsWorkspace(workspaceId) {
                return monitorId
            }
        }
        return nil
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        for niriMonitor in monitors.values {
            if niriMonitor.containsWorkspace(workspaceId) {
                return niriMonitor
            }
        }
        return nil
    }
}
