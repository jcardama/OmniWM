import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

private func makeOverviewProjectionWindow(
    model: WindowModel,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int,
    frame: CGRect,
    title: String
) -> (handle: WindowHandle, data: OverviewWindowLayoutData) {
    let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
    let token = model.upsert(
        window: axRef,
        pid: pid_t(windowId),
        windowId: windowId,
        workspace: workspaceId
    )
    guard let handle = model.handle(for: token) else {
        fatalError("Expected overview projection bridge handle")
    }
    let entry = model.entry(for: handle)!
    return (
        handle,
        (
            entry: entry,
            title: title,
            appName: "App",
            appIcon: nil,
            frame: frame
        )
    )
}

private func frameIsWithinViewport(_ frame: CGRect, viewport: CGRect) -> Bool {
    frame.minX >= viewport.minX &&
        frame.maxX <= viewport.maxX &&
        frame.minY >= viewport.minY &&
        frame.maxY <= viewport.maxY
}

@Suite struct OverviewProjectionTests {
    @Test @MainActor func localizedFrameTranslatesOffsetMonitorIntoPanelCoordinates() {
        let monitorFrame = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let globalFrame = CGRect(x: 2048, y: 120, width: 800, height: 600)

        let localized = OverviewLayoutCalculator.localizedFrame(globalFrame, to: monitorFrame)

        #expect(localized == CGRect(x: 320, y: 120, width: 800, height: 600))
    }

    @Test @MainActor func projectedLayoutsKeepWindowsVisibleAcrossOriginAndOffsetMonitors() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let first = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 101,
            frame: CGRect(x: 120, y: 80, width: 900, height: 700),
            title: "Alpha"
        )
        let second = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 102,
            frame: CGRect(x: 2080, y: 140, width: 960, height: 720),
            title: "Beta"
        )
        let windows: [WindowHandle: OverviewWindowLayoutData] = [
            first.handle: first.data,
            second.handle: second.data
        ]

        let originMonitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offsetMonitor = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let originViewport = OverviewLayoutCalculator.viewportFrame(for: originMonitor)
        let offsetViewport = OverviewLayoutCalculator.viewportFrame(for: offsetMonitor)

        let originLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windows.mapValues { data in
                (
                    entry: data.entry,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: originMonitor)
                )
            },
            screenFrame: originViewport,
            searchQuery: "",
            scale: 1.0
        )
        let offsetLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windows.mapValues { data in
                (
                    entry: data.entry,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: offsetMonitor)
                )
            },
            screenFrame: offsetViewport,
            searchQuery: "",
            scale: 1.0
        )

        #expect(originLayout.allWindows.count == 2)
        #expect(offsetLayout.allWindows.count == 2)
        #expect(originLayout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: originViewport) })
        #expect(offsetLayout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: offsetViewport) })
        #expect(offsetLayout.allWindows.contains { $0.originalFrame.minX < 0 })
        #expect(offsetLayout.allWindows.contains { $0.originalFrame.minX > 0 })
    }

    @Test @MainActor func zoomScaleLayoutsStayNonEmptyOnOriginAndOffsetMonitors() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for (index, x) in stride(from: 0, through: 2200, by: 275).enumerated() {
            let window = makeOverviewProjectionWindow(
                model: model,
                workspaceId: workspaceId,
                windowId: 200 + index,
                frame: CGRect(x: CGFloat(x), y: CGFloat(60 + (index % 3) * 80), width: 800, height: 620),
                title: "Window \(index)"
            )
            windows[window.handle] = window.data
        }

        let originMonitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offsetMonitor = CGRect(x: 1728, y: 0, width: 1728, height: 1117)

        for scale in [CGFloat(1.0), 1.25] {
            for monitorFrame in [originMonitor, offsetMonitor] {
                let viewport = OverviewLayoutCalculator.viewportFrame(for: monitorFrame)
                let layout = OverviewLayoutCalculator.calculateLayout(
                    workspaces: workspaces,
                    windows: windows.mapValues { data in
                        (
                            entry: data.entry,
                            title: data.title,
                            appName: data.appName,
                            appIcon: data.appIcon,
                            frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: monitorFrame)
                        )
                    },
                    screenFrame: viewport,
                    searchQuery: "",
                    scale: scale
                )

                #expect(!layout.allWindows.isEmpty)
                #expect(layout.allWindows.count == windows.count)
                #expect(layout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: viewport) })
            }
        }
    }

    @Test @MainActor func localizedAnimationFramesAndZoomClampStayInPanelSpace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for index in 0 ..< 10 {
            let window = makeOverviewProjectionWindow(
                model: model,
                workspaceId: workspaceId,
                windowId: 400 + index,
                frame: CGRect(
                    x: 1880 + CGFloat(index * 60),
                    y: 50 + CGFloat((index % 4) * 45),
                    width: 720,
                    height: 540
                ),
                title: "App \(index)"
            )
            windows[window.handle] = window.data
        }

        let monitorFrame = CGRect(x: 1728, y: 0, width: 1440, height: 900)
        let viewport = OverviewLayoutCalculator.viewportFrame(for: monitorFrame)
        let localizedWindows = windows.mapValues { data in
            (
                entry: data.entry,
                title: data.title,
                appName: data.appName,
                appIcon: data.appIcon,
                frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: monitorFrame)
            )
        }

        let baseLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: localizedWindows,
            screenFrame: viewport,
            searchQuery: "",
            scale: 1.0
        )
        let zoomedLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: localizedWindows,
            screenFrame: viewport,
            searchQuery: "",
            scale: 1.25
        )

        let sampleWindow = zoomedLayout.allWindows.first!
        let interpolated = sampleWindow.interpolatedFrame(progress: 0.5)
        let clampedOffset = OverviewLayoutCalculator.clampedScrollOffset(
            -500,
            layout: zoomedLayout,
            screenFrame: viewport
        )
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
            layout: zoomedLayout,
            screenFrame: viewport
        )

        #expect(sampleWindow.originalFrame.minX < viewport.maxX)
        #expect(sampleWindow.originalFrame.minX >= -monitorFrame.width)
        #expect(frameIsWithinViewport(sampleWindow.overviewFrame, viewport: viewport))
        #expect(interpolated.minX >= sampleWindow.originalFrame.minX)
        #expect(interpolated.maxX <= max(sampleWindow.originalFrame.maxX, sampleWindow.overviewFrame.maxX))
        #expect(bounds.contains(clampedOffset))
        #expect(zoomedLayout.allWindows.count == baseLayout.allWindows.count)
    }
}
