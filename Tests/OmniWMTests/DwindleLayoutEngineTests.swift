import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite struct DwindleLayoutEngineTests {
    @Test func syncWindowsKeepsStableNodeForReobservedToken() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()

        let original = makeTestHandle(pid: 31)
        let refreshed = WindowHandle(
            id: original.id,
            pid: original.pid,
            axElement: AXUIElementCreateSystemWide()
        )

        _ = engine.syncWindows([original], in: wsId, focusedHandle: original)
        let originalNodeId = engine.findNode(for: original.id)?.id

        _ = engine.syncWindows([refreshed], in: wsId, focusedHandle: refreshed)

        #expect(engine.windowCount(in: wsId) == 1)
        #expect(engine.findNode(for: refreshed.id)?.id == originalNodeId)
    }

    @Test func layoutAndFrameCachesUseStableTokens() {
        let engine = DwindleLayoutEngine()
        let wsId = UUID()
        let handle1 = makeTestHandle(pid: 41)
        let handle2 = makeTestHandle(pid: 42)

        _ = engine.syncWindows([handle1, handle2], in: wsId, focusedHandle: handle1)

        let baseFrames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        #expect(Set(baseFrames.keys) == Set([handle1.id, handle2.id]))

        let currentFrames = engine.currentFrames(in: wsId)
        #expect(Set(currentFrames.keys) == Set([handle1.id, handle2.id]))

        engine.removeWindow(token: handle2.id, from: wsId)

        let updatedFrames = engine.calculateLayout(
            for: wsId,
            screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        #expect(Set(updatedFrames.keys) == Set([handle1.id]))
        #expect(engine.findNode(for: handle2.id) == nil)
    }
}
