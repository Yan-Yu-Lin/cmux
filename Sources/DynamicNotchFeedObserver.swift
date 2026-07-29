import CMUXAgentLaunch
import Foundation
import Observation

/// Bridges the app-wide observable Feed store into immutable Dynamic Notch
/// snapshots without making row views observe the live store.
@MainActor
final class DynamicNotchFeedObserver {
    private let changed: ([WorkstreamItem]) -> Void
    private var storeInstalledObserver: NSObjectProtocol?
    private var isStarted = false

    init(changed: @escaping ([WorkstreamItem]) -> Void) {
        self.changed = changed
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        storeInstalledObserver = NotificationCenter.default.addObserver(
            forName: FeedCoordinator.storeInstalledNotification,
            object: FeedCoordinator.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.arm()
            }
        }
        arm()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(
                storeInstalledObserver
            )
            self.storeInstalledObserver = nil
        }
    }

    deinit {
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(
                storeInstalledObserver
            )
        }
    }

    private func arm() {
        guard isStarted else { return }
        guard let store = FeedCoordinator.shared.store else {
            changed([])
            return
        }
        withObservationTracking {
            changed(store.items)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.arm()
            }
        }
    }
}
