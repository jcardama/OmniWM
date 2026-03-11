import Foundation
import QuartzCore

struct WorkspaceSwitch {
    let orderedWorkspaceIds: [WorkspaceDescriptor.ID]
    let fromWorkspaceId: WorkspaceDescriptor.ID
    let toWorkspaceId: WorkspaceDescriptor.ID

    private var animation: SpringAnimation

    init(
        orderedWorkspaceIds: [WorkspaceDescriptor.ID],
        fromWorkspaceId: WorkspaceDescriptor.ID,
        toWorkspaceId: WorkspaceDescriptor.ID,
        animation: SpringAnimation
    ) {
        self.orderedWorkspaceIds = orderedWorkspaceIds
        self.fromWorkspaceId = fromWorkspaceId
        self.toWorkspaceId = toWorkspaceId
        self.animation = animation
    }

    func index(of workspaceId: WorkspaceDescriptor.ID) -> Int? {
        orderedWorkspaceIds.firstIndex(of: workspaceId)
    }

    func currentIndex(at time: TimeInterval = CACurrentMediaTime()) -> Double {
        animation.value(at: time)
    }

    func isAnimating(at time: TimeInterval = CACurrentMediaTime()) -> Bool {
        !animation.isComplete(at: time)
    }

    mutating func tick(at time: TimeInterval) -> Bool {
        !animation.isComplete(at: time)
    }
}
