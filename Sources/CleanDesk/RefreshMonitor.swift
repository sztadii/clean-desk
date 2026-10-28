import Foundation

/// Cancelling a scheduled refresh is idempotent and also happens on release.
final class RefreshCancellation {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }

    deinit { cancellation?() }
}

@MainActor
protocol RefreshScheduling {
    func schedule(after interval: TimeInterval, repeating: Bool,
                  action: @escaping @MainActor () -> Void) -> RefreshCancellation
}

@MainActor
private final class RunLoopRefreshScheduler: RefreshScheduling {
    func schedule(after interval: TimeInterval, repeating: Bool,
                  action: @escaping @MainActor () -> Void) -> RefreshCancellation {
        let timer = Timer(timeInterval: interval, repeats: repeating) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = repeating ? 0.4 : 0.03
        // Context menus run in a tracking mode. Their enabled state must remain fresh too.
        RunLoop.main.add(timer, forMode: .common)
        return RefreshCancellation { timer.invalidate() }
    }
}

/// Keeps a visible panel/menu fresh, without polling or rebuilding hidden UI.
/// Workspace events are coalesced; visible polling also catches Finder window
/// changes and apps whose activation policy changes after a launch notification.
@MainActor
final class RefreshMonitor {
    private let scheduler: any RefreshScheduling
    private let onRefresh: @MainActor () -> Void
    private var periodicRefresh: RefreshCancellation?
    private var pendingRefresh: RefreshCancellation?
    private var pendingID: UUID?
    private var generation: UInt64 = 0

    private(set) var isVisible = false
    private(set) var isDirty = true

    init(onRefresh: @escaping @MainActor () -> Void, scheduler: (any RefreshScheduling)? = nil) {
        self.onRefresh = onRefresh
        self.scheduler = scheduler ?? RunLoopRefreshScheduler()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        generation &+= 1
        cancelPendingRefresh()
        periodicRefresh?.cancel()
        periodicRefresh = nil
        guard visible else { return }

        let currentGeneration = generation
        periodicRefresh = scheduler.schedule(after: 2, repeating: true) { [weak self] in
            guard let self, self.isVisible, self.generation == currentGeneration else { return }
            self.performRefresh()
        }
        // Always refresh on opening: Desktop files and Finder windows have no
        // corresponding NSWorkspace application notification.
        performRefresh()
    }

    func applicationStateChanged() {
        isDirty = true
        guard isVisible, pendingRefresh == nil else { return }
        let currentGeneration = generation
        let id = UUID()
        pendingID = id
        pendingRefresh = scheduler.schedule(after: 0.1, repeating: false) { [weak self] in
            guard let self, self.isVisible, self.generation == currentGeneration,
                  self.pendingID == id else { return }
            self.performRefresh()
        }
    }

    private func performRefresh() {
        cancelPendingRefresh()
        isDirty = false
        onRefresh()
    }

    private func cancelPendingRefresh() {
        pendingID = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    deinit {
        periodicRefresh?.cancel()
        pendingRefresh?.cancel()
    }
}
