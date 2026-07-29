import CMUXAgentLaunch
import CmuxSettings
import Foundation
import Observation

enum DynamicNotchNotificationPhase: Equatable {
    case retracted
    case compact
    case expanded
}

enum DynamicNotchTraySection: String, CaseIterable, Equatable {
    case feed
    case unread
}

/// Main-actor state for the accumulated Dynamic Notch notification tray.
@MainActor
@Observable
final class DynamicNotchNotificationTrayModel {
    private(set) var notifications: [TerminalNotification] = []
    private(set) var feedItems: [WorkstreamItem] = []
    private(set) var unreadNotifications: [TerminalNotification] = []
    private(set) var phase: DynamicNotchNotificationPhase = .retracted
    private(set) var selectedSection: DynamicNotchTraySection = .feed
    private(set) var globalAppearance: DynamicNotchAppearance
    private(set) var displayHorizontalPosition: Double?
    private(set) var displayExpandedSize: DynamicNotchDisplaySize?
    private(set) var maximumExpandedSize: DynamicNotchDisplaySize?
    private(set) var swipeActions: DynamicNotchSwipeActions
    private(set) var keepsDefaultIslandVisible: Bool
    private(set) var contentRevision = 0
    private var hiddenFeedItemIDs: Set<UUID> = []
    private var hiddenUnreadNotificationIDs: Set<UUID> = []

    init(
        globalAppearance: DynamicNotchAppearance = DynamicNotchAppearance(),
        displayHorizontalPosition: Double? = nil,
        displayExpandedSize: DynamicNotchDisplaySize? = nil,
        maximumExpandedSize: DynamicNotchDisplaySize? = nil,
        swipeActions: DynamicNotchSwipeActions =
            DynamicNotchSwipeActions(),
        keepsDefaultIslandVisible: Bool = false
    ) {
        self.globalAppearance = globalAppearance
        self.displayHorizontalPosition = displayHorizontalPosition
        self.displayExpandedSize = displayExpandedSize
        self.maximumExpandedSize = maximumExpandedSize
        self.swipeActions = swipeActions
        self.keepsDefaultIslandVisible = keepsDefaultIslandVisible
    }

    /// Tray-wide dimensions and chrome follow the newest pending notification.
    var trayAppearance: DynamicNotchAppearance {
        guard let notification = notifications.first else {
            return globalAppearance
        }
        return appearance(for: notification)
    }

    /// Each accumulated row retains the overrides it was created with.
    func appearance(
        for notification: TerminalNotification
    ) -> DynamicNotchAppearance {
        let appearance = globalAppearance.applying(
            notification.presentation.appearance
        )
        guard let displayHorizontalPosition else { return appearance }
        return appearance.replacing(
            .number(displayHorizontalPosition),
            for: .syntheticNotchHorizontalPosition
        )
    }

    var isAvailable: Bool {
        keepsDefaultIslandVisible
            || !notifications.isEmpty
            || !feedItems.isEmpty
            || !unreadNotifications.isEmpty
    }

    var feedCount: Int {
        notifications.count + feedItems.count
    }

    var unreadCount: Int {
        unreadNotifications.count
    }

    var badgeCount: Int {
        let notificationIDs = Set(notifications.map(\.id))
        let uniqueUnreadCount = unreadNotifications.lazy.filter {
            !notificationIDs.contains($0.id)
        }.count
        return notifications.count + feedItems.count + uniqueUnreadCount
    }

    var resolvedExpandedWidth: Double {
        let requested = displayExpandedSize?.width
            ?? Double(trayAppearance.dimension(.expandedWidth))
        return min(
            requested,
            maximumExpandedSize?.width ?? requested
        )
    }

    var resolvedExpandedHeight: Double {
        let requested = displayExpandedSize?.height
            ?? Double(trayAppearance.dimension(.maximumExpandedHeight))
        return min(
            requested,
            maximumExpandedSize?.height ?? requested
        )
    }

    @discardableResult
    func enqueue(_ notification: TerminalNotification) -> Bool {
        guard !notifications.contains(where: { $0.id == notification.id }) else {
            return false
        }
        notifications.insert(notification, at: 0)
        contentRevision &+= 1
        return true
    }

    /// Refreshes one notification identity and moves it to the front in one
    /// observable mutation. Different notification IDs always accumulate.
    @discardableResult
    func upsert(_ notification: TerminalNotification) -> TerminalNotification? {
        var replaced: TerminalNotification?
        notifications.removeAll { existing in
            guard existing.id == notification.id else { return false }
            replaced = existing
            return true
        }
        notifications.insert(notification, at: 0)
        contentRevision &+= 1
        return replaced
    }

    func notification(id: UUID) -> TerminalNotification? {
        notifications.first(where: { $0.id == id })
    }

    @discardableResult
    func remove(id: UUID) -> TerminalNotification? {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let notification = notifications.remove(at: index)
        contentRevision &+= 1
        if !isAvailable {
            phase = .retracted
        }
        return notification
    }

    func remove(ids: Set<UUID>) -> [TerminalNotification] {
        var removed: [TerminalNotification] = []
        notifications.removeAll { notification in
            guard ids.contains(notification.id) else { return false }
            removed.append(notification)
            return true
        }
        if !removed.isEmpty {
            contentRevision &+= 1
        }
        if !isAvailable {
            phase = .retracted
        }
        return removed
    }

    func removeAll() -> [TerminalNotification] {
        let removed = notifications
        notifications.removeAll()
        if !removed.isEmpty {
            contentRevision &+= 1
        }
        if !isAvailable {
            phase = .retracted
        }
        return removed
    }

    func transition(to phase: DynamicNotchNotificationPhase) {
        self.phase = isAvailable ? phase : .retracted
    }

    func setGlobalAppearance(_ appearance: DynamicNotchAppearance) {
        globalAppearance = appearance
    }

    func setDisplayHorizontalPosition(_ position: Double?) {
        displayHorizontalPosition = position
    }

    func setDisplayExpandedSize(_ size: DynamicNotchDisplaySize?) {
        guard displayExpandedSize != size else { return }
        displayExpandedSize = size
        contentRevision &+= 1
    }

    func setMaximumExpandedSize(_ size: DynamicNotchDisplaySize?) {
        guard maximumExpandedSize != size else { return }
        maximumExpandedSize = size
        contentRevision &+= 1
    }

    func setSwipeActions(_ actions: DynamicNotchSwipeActions) {
        swipeActions = actions
    }

    func setKeepsDefaultIslandVisible(_ enabled: Bool) {
        guard keepsDefaultIslandVisible != enabled else { return }
        keepsDefaultIslandVisible = enabled
        if !isAvailable {
            phase = .retracted
        }
    }

    func setSelectedSection(_ section: DynamicNotchTraySection) {
        selectedSection = section
    }

    func setFeedItems(_ items: [WorkstreamItem]) {
        let pendingIDs = Set(
            items.lazy.filter(\.status.isPending).map(\.id)
        )
        hiddenFeedItemIDs.formIntersection(pendingIDs)
        let nextItems = Array(
            items.lazy.reversed().filter {
                $0.status.isPending && !hiddenFeedItemIDs.contains($0.id)
            }
            .prefix(WorkstreamDefaultRingCapacity)
        )
        guard feedItems != nextItems else { return }
        feedItems = nextItems
        contentRevision &+= 1
    }

    func hideFeedItem(id: UUID) {
        hiddenFeedItemIDs.insert(id)
        guard let index = feedItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        feedItems.remove(at: index)
        contentRevision &+= 1
    }

    func setUnreadNotifications(_ notifications: [TerminalNotification]) {
        let unreadIDs = Set(
            notifications.lazy.filter { !$0.isRead }.map(\.id)
        )
        hiddenUnreadNotificationIDs.formIntersection(unreadIDs)
        let nextNotifications = notifications.filter {
            !$0.isRead && !hiddenUnreadNotificationIDs.contains($0.id)
        }
        guard unreadNotifications != nextNotifications else { return }
        unreadNotifications = nextNotifications
        contentRevision &+= 1
    }

    func hideUnreadNotification(id: UUID) {
        hiddenUnreadNotificationIDs.insert(id)
        guard let index = unreadNotifications.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        unreadNotifications.remove(at: index)
        contentRevision &+= 1
    }
}
