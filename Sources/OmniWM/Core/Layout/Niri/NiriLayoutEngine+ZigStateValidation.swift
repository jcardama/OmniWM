import Foundation

extension NiriLayoutEngine {
    func validateStateSnapshotWithZig(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let snapshot = NiriStateZigKernel.makeSnapshot(columns: columns(in: workspaceId))
        return NiriStateZigKernel.validate(snapshot: snapshot).isValid
    }
}
