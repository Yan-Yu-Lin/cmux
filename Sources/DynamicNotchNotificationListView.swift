import AppKit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxSettings
import SwiftUI

/// One virtualized scroll surface for runtime notifications, cmux Feed cards,
/// and unread terminal notifications. This lazy subtree receives immutable
/// snapshots only, never the live tray model, so unrelated observation changes
/// cannot invalidate every realized row.
struct DynamicNotchNotificationListView: View {
    let notifications: [TerminalNotification]
    let feedItems: [WorkstreamItem]
    let unreadNotifications: [TerminalNotification]
    let phase: DynamicNotchNotificationPhase
    let selectedSection: DynamicNotchTraySection
    let globalAppearance: DynamicNotchAppearance
    let trayAppearance: DynamicNotchAppearance
    let swipeActions: DynamicNotchSwipeActions
    let expandedWidth: CGFloat
    let contentRevision: Int
    let viewportHeight: CGFloat
    let contentHeightChanged: (CGFloat) -> Void
    let performNotificationAction:
        (String, [String: String], TerminalNotification) -> Void
    let performFeedAction: (String, WorkstreamItem) -> Void
    let performUnreadAction: (String, TerminalNotification) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollTargetID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch selectedSection {
                case .feed:
                    feedRows
                case .unread:
                    unreadRows
                }
            }
            .scrollTargetLayout()
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: animationDuration),
                value: contentRevision
            )
            .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                contentHeightChanged($0)
            }
            .background {
                SidebarScrollViewResolver { scrollView in
                    scrollView?.applyDynamicNotchScrollerConfiguration(
                        showsIndicators: trayAppearance.boolean(
                            .showScrollIndicators
                        )
                    )
                }
                .frame(width: 0, height: 0)
            }
        }
        .defaultScrollAnchor(.top)
        .scrollPosition(id: $scrollTargetID, anchor: .top)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.horizontal, 0, for: .scrollIndicators)
        .frame(
            width: expandedWidth,
            height: viewportHeight
        )
        .onChange(of: newestVisibleID) { _, newestID in
            scrollToNewest(newestID, animated: true)
        }
        .onChange(of: phase) { _, phase in
            guard phase == .expanded else { return }
            scrollToNewest(newestVisibleID, animated: false)
        }
        .onChange(of: selectedSection) { _, _ in
            scrollToNewest(newestVisibleID, animated: false)
        }
        .accessibilityIdentifier("DynamicNotchNotificationList")
    }

    @ViewBuilder
    private var feedRows: some View {
        if notifications.isEmpty && feedItems.isEmpty {
            emptyState(
                symbol: "bolt.horizontal.circle",
                title: String(
                    localized: "notification.dynamicNotch.feed.empty",
                    defaultValue: "No pending Feed actions"
                )
            )
        } else {
            ForEach(notifications) { notification in
                swipeContainer(
                    rowKind: .notification,
                    notification: notification
                ) {
                    DynamicNotchNotificationView(
                        notification: notification,
                        isTrayExpanded: phase == .expanded,
                        shouldAutofocus:
                            notification.id == notifications.first?.id,
                        appearance: globalAppearance.applying(
                            notification.presentation.appearance
                        )
                    ) { action, values in
                        performNotificationAction(
                            action,
                            values,
                            notification
                        )
                    }
                    .equatable()
                }
                .id(notification.id)
                rowDivider
            }

            ForEach(feedItems) { item in
                swipeContainer(rowKind: .feed, feedItem: item) {
                    DynamicNotchFeedItemView(item: item) {
                        performFeedAction("open", item)
                    }
                    .equatable()
                }
                .id(item.id)
                rowDivider
            }
        }
    }

    @ViewBuilder
    private var unreadRows: some View {
        if unreadNotifications.isEmpty {
            emptyState(
                symbol: "checkmark.circle",
                title: String(
                    localized: "notification.dynamicNotch.unread.empty",
                    defaultValue: "No unread notifications"
                )
            )
        } else {
            ForEach(unreadNotifications) { notification in
                swipeContainer(
                    rowKind: .unread,
                    notification: notification
                ) {
                    DynamicNotchUnreadNotificationView(
                        notification: notification,
                        appearance: globalAppearance,
                        open: {
                            performUnreadAction("open", notification)
                        },
                        markRead: {
                            performUnreadAction("markRead", notification)
                        },
                        dismiss: {
                            performUnreadAction("dismiss", notification)
                        }
                    )
                    .equatable()
                }
                .id(notification.id)
                rowDivider
            }
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(
                trayAppearance.color(
                    .dividerColor,
                    system: Color(nsColor: .separatorColor)
                )
            )
            .padding(
                .horizontal,
                trayAppearance.dimension(.dividerHorizontalPadding)
            )
    }

    private func emptyState(
        symbol: String,
        title: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
    }

    private func swipeContainer<Content: View>(
        rowKind: DynamicNotchSwipeRowKind,
        notification: TerminalNotification? = nil,
        feedItem: WorkstreamItem? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DynamicNotchSwipeContainer(
            leftAction: swipeDescriptor(
                rowKind: rowKind,
                direction: .left,
                notification: notification
            ),
            rightAction: swipeDescriptor(
                rowKind: rowKind,
                direction: .right,
                notification: notification
            ),
            perform: { descriptor in
                if let notification {
                    if rowKind == .unread {
                        performUnreadAction(descriptor.id, notification)
                    } else {
                        performNotificationAction(
                            descriptor.id,
                            [:],
                            notification
                        )
                    }
                } else if let feedItem {
                    performFeedAction(descriptor.id, feedItem)
                }
            },
            content: content
        )
    }

    private func swipeDescriptor(
        rowKind: DynamicNotchSwipeRowKind,
        direction: DynamicNotchSwipeDirection,
        notification: TerminalNotification?
    ) -> DynamicNotchSwipeActionDescriptor? {
        let override: TerminalNotificationPresentation.SwipeAction? = {
            guard rowKind == .notification else { return nil }
            return direction == .left
                ? notification?.presentation.swipeLeftAction
                : notification?.presentation.swipeRightAction
        }()
        let id: String
        let explicitTitle: String?
        if let override {
            id = override.id
            explicitTitle = override.title
        } else {
            let action = swipeActions.action(
                for: rowKind,
                direction: direction
            )
            guard action != .none else { return nil }
            id = action.rawValue
            explicitTitle = nil
        }

        let normalizedID = id == "mark-read" ? "markRead" : id
        let builtIn = DynamicNotchSwipeAction(rawValue: normalizedID)
        if let builtIn, builtIn == DynamicNotchSwipeAction.none {
            return nil
        }
        let customAction = notification?.presentation.actions.first {
            $0.id == id
        }
        guard builtIn != nil || customAction != nil else { return nil }
        let appearance = trayAppearance
        return DynamicNotchSwipeActionDescriptor(
            id: normalizedID,
            title: explicitTitle
                ?? customAction?.title
                ?? builtIn?.dynamicNotchTitle
                ?? id,
            symbolName:
                builtIn?.dynamicNotchSymbolName ?? "hand.tap",
            background: appearance.color(
                direction == .left
                    ? .swipeLeftBackgroundColor
                    : .swipeRightBackgroundColor,
                system: direction == .left ? .red : .blue
            ),
            foreground: appearance.color(
                .swipeActionForegroundColor,
                system: .white
            )
        )
    }

    private var newestVisibleID: UUID? {
        switch selectedSection {
        case .feed:
            notifications.first?.id ?? feedItems.first?.id
        case .unread:
            unreadNotifications.first?.id
        }
    }

    private func scrollToNewest(
        _ newestID: UUID?,
        animated: Bool
    ) {
        guard phase == .expanded, let newestID else { return }
        if reduceMotion || !animated {
            scrollTargetID = newestID
        } else {
            withAnimation(.snappy(duration: animationDuration)) {
                scrollTargetID = newestID
            }
        }
    }

    private var animationDuration: Double {
        Double(trayAppearance.dimension(.animationDuration))
    }
}

private extension NSScrollView {
    @MainActor
    func applyDynamicNotchScrollerConfiguration(
        showsIndicators: Bool
    ) {
        applyOverlayScrollerConfiguration(
            showsVerticalScroller: showsIndicators
        )
        if automaticallyAdjustsContentInsets {
            automaticallyAdjustsContentInsets = false
        }

        let currentContentInsets = contentInsets
        if currentContentInsets.left != 0 || currentContentInsets.right != 0 {
            contentInsets = NSEdgeInsets(
                top: currentContentInsets.top,
                left: 0,
                bottom: currentContentInsets.bottom,
                right: 0
            )
        }

        let currentScrollerInsets = scrollerInsets
        if currentScrollerInsets.left != 0
            || currentScrollerInsets.right != 0 {
            scrollerInsets = NSEdgeInsets(
                top: currentScrollerInsets.top,
                left: 0,
                bottom: currentScrollerInsets.bottom,
                right: 0
            )
        }
    }
}
