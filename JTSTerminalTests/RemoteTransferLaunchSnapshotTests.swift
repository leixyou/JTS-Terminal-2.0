import Testing
@testable import JTSTerminal

@MainActor
struct RemoteTransferLaunchSnapshotTests {
    @Test func queuedTransferFieldsRemainBoundToOriginalUserRequest() {
        let session = RemoteSession(
            host: "original.example",
            username: "original-user",
            port: 2_222,
            identityFile: "/tmp/original-key"
        )
        let task = RemoteTransferTask(
            session: session,
            direction: .upload,
            remotePath: "/srv/original.txt",
            localPath: "/tmp/original.txt",
            recursive: false
        )
        let destination = SSHSessionLaunchSnapshot(session: session)
        let transfer = RemoteTransferLaunchSnapshot(task: task)

        session.host = "edited.example"
        session.username = "edited-user"
        session.port = 2_202
        session.identityFile = "/tmp/edited-key"
        task.direction = .download
        task.remotePath = "/srv/edited.txt"
        task.localPath = "/tmp/edited.txt"
        task.recursive = true

        #expect(destination.host == "original.example")
        #expect(destination.username == "original-user")
        #expect(destination.port == 2_222)
        #expect(destination.identityFile == "/tmp/original-key")
        #expect(transfer.direction == .upload)
        #expect(transfer.remotePath == "/srv/original.txt")
        #expect(transfer.localPath == "/tmp/original.txt")
        #expect(!transfer.recursive)
    }
}
