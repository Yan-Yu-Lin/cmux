import CMUXAgentLaunch
import CmuxSettings
import SwiftUI

/// Hover-expanded, resizable tray containing cmux Feed and unread views.
struct DynamicNotchNotificationTrayView: View {
    let model: DynamicNotchNotificationTrayModel
    let performNotificationAction:
        (String, [String: String], TerminalNotification) -> Void
    let performFeedAction: (String, WorkstreamItem) -> Void
    let performUnreadAction: (String, TerminalNotification) -> Void
    let resizeChanged: (CGSize) -> Void
    let resizeEnded: (CGSize) -> Void

    @State private var listContentHeight: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let headerHeight: CGFloat = 44

    var body: some View {
        let appearance = model.trayAppearance
        let animationDuration = Double(
            appearance.dimension(.animationDuration)
        )
        let expandedHeight = resolvedExpandedHeight
        let viewportHeight = max(1, expandedHeight - headerHeight)

        VStack(spacing: 0) {
            sectionHeader
                .frame(height: headerHeight)

            DynamicNotchNotificationListView(
                notifications: model.notifications,
                feedItems: model.feedItems,
                unreadNotifications: model.unreadNotifications,
                phase: model.phase,
                selectedSection: model.selectedSection,
                globalAppearance: model.globalAppearance,
                trayAppearance: model.trayAppearance,
                swipeActions: model.swipeActions,
                expandedWidth: CGFloat(model.resolvedExpandedWidth),
                contentRevision: model.contentRevision,
                viewportHeight: viewportHeight,
                contentHeightChanged: { height in
                    if reduceMotion {
                        listContentHeight = height
                    } else {
                        withAnimation(
                            .snappy(duration: animationDuration)
                        ) {
                            listContentHeight = height
                        }
                    }
                },
                performNotificationAction: performNotificationAction,
                performFeedAction: performFeedAction,
                performUnreadAction: performUnreadAction
            )
        }
        .frame(
            width: CGFloat(model.resolvedExpandedWidth),
            height: expandedHeight,
            alignment: .top
        )
        .overlay(alignment: .trailing) {
            DynamicNotchResizeSurface(
                axis: .horizontal,
                currentSize: currentSize,
                changed: resizeChanged,
                ended: resizeEnded
            )
            .frame(width: 7)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            DynamicNotchResizeSurface(
                axis: .vertical,
                currentSize: currentSize,
                changed: resizeChanged,
                ended: resizeEnded
            )
            .frame(height: 7)
            .padding(.trailing, 14)
        }
        .overlay(alignment: .bottomTrailing) {
            DynamicNotchResizeSurface(
                axis: .both,
                currentSize: currentSize,
                changed: resizeChanged,
                ended: resizeEnded
            )
            .frame(width: 16, height: 16)
            .accessibilityLabel(
                String(
                    localized:
                        "notification.dynamicNotch.resize.accessibility",
                    defaultValue: "Resize Dynamic Notch"
                )
            )
        }
        .contentShape(Rectangle())
        .clipped()
        .animation(
            reduceMotion ? nil : .snappy(duration: animationDuration),
            value: model.contentRevision
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: animationDuration),
            value: model.resolvedExpandedWidth
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: animationDuration),
            value: model.resolvedExpandedHeight
        )
        .tint(appearance.color(.accentColor, system: .accentColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DynamicNotchNotificationTray")
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            sectionButton(
                .feed,
                title: String(
                    localized: "notification.dynamicNotch.feed",
                    defaultValue: "Feed"
                ),
                count: model.feedCount
            )
            sectionButton(
                .unread,
                title: String(
                    localized: "notification.dynamicNotch.unread",
                    defaultValue: "Unread"
                ),
                count: model.unreadCount
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(
                    model.trayAppearance.color(
                        .dividerColor,
                        system: Color(nsColor: .separatorColor)
                    )
                )
        }
    }

    private func sectionButton(
        _ section: DynamicNotchTraySection,
        title: String,
        count: Int
    ) -> some View {
        Button {
            model.setSelectedSection(section)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        model.selectedSection == section
                            ? Color.white.opacity(0.14)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "DynamicNotchSection.\(section.rawValue)"
        )
    }

    private var resolvedExpandedHeight: CGFloat {
        let configured = CGFloat(model.resolvedExpandedHeight)
        if model.keepsDefaultIslandVisible
            || model.displayExpandedSize != nil {
            return configured
        }
        return min(
            configured,
            CGFloat(
                max(
                    DynamicNotchDisplaySize.heightRange.lowerBound,
                    Double(headerHeight + listContentHeight)
                )
            )
        )
    }

    private func currentSize() -> CGSize {
        CGSize(
            width: CGFloat(model.resolvedExpandedWidth),
            height: CGFloat(model.resolvedExpandedHeight)
        )
    }
}
