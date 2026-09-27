#if ENABLE_RDP_2
import Foundation

/// A new viewport/policy always supersedes pending work, even when it needs no
/// resize. This prevents a stale full-screen proposal from winning 400 ms later.
@MainActor
final class RDPDesktopResizeCoordinator {
    private let debounce: Duration
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(400)) { self.debounce = debounce }

    func schedule(viewport: CGSize, remote: CGSize, enabled: Bool, sessionID: UUID?,
                  isStillAllowed: @escaping () -> Bool, send: @escaping (Int, Int) -> Void) {
        cancel()
        guard enabled, sessionID != nil, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return }
        let width = Int(min(max(viewport.width.rounded(), 640), 7_680))
        let height = Int(min(max(viewport.height.rounded(), 480), 4_320))
        guard abs(remote.width - CGFloat(width)) >= 8 || abs(remote.height - CGFloat(height)) >= 8 else { return }
        let token = generation
        let delay = debounce
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled, isStillAllowed() else { return }
            self.pending = nil
            send(width, height)
        }
    }

    func cancel() {
        generation = UUID()
        pending?.cancel()
        pending = nil
    }
}
#endif
