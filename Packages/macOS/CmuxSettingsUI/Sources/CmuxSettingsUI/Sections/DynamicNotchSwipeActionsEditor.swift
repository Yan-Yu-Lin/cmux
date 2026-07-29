import CmuxFoundation
import CmuxSettings
import SwiftUI

@MainActor
struct DynamicNotchSwipeActionsEditor: View {
    let model: DefaultsValueModel<DynamicNotchSwipeActions>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        String(
                            localized:
                                "settings.notifications.dynamicNotch.swipe.title",
                            defaultValue: "Dynamic Notch Swipe Actions"
                        )
                    )
                    .cmuxFont(size: 17, weight: .semibold)
                    Text(
                        String(
                            localized:
                                "settings.notifications.dynamicNotch.swipe.subtitle",
                            defaultValue:
                                "Choose what a completed left or right swipe does for each kind of row."
                        )
                    )
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    String(
                        localized:
                            "settings.notifications.dynamicNotch.editor.resetAll",
                        defaultValue: "Reset All"
                    )
                ) {
                    model.reset()
                }
                .disabled(model.current == DynamicNotchSwipeActions())
            }
            .padding(20)

            Divider()

            SettingsCard {
                ForEach(
                    Array(DynamicNotchSwipeRowKind.allCases.enumerated()),
                    id: \.element.rawValue
                ) { index, rowKind in
                    SettingsCardRow(
                        configurationReview: .json(
                            "notifications.dynamicNotchSwipeActions.\(rowKind.rawValue)"
                        ),
                        rowKind.localizedTitle,
                        subtitle: rowKind.localizedSummary
                    ) {
                        HStack(spacing: 8) {
                            actionPicker(
                                rowKind: rowKind,
                                direction: .left
                            )
                            actionPicker(
                                rowKind: rowKind,
                                direction: .right
                            )
                        }
                    }
                    if index < DynamicNotchSwipeRowKind.allCases.count - 1 {
                        SettingsCardDivider()
                    }
                }
            }
            .padding(20)

            Spacer()
            Divider()
            HStack {
                Spacer()
                Button(
                    String(localized: "common.done", defaultValue: "Done")
                ) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 680, minHeight: 390)
        .accessibilityIdentifier("DynamicNotchSwipeActionsEditor")
    }

    private func actionPicker(
        rowKind: DynamicNotchSwipeRowKind,
        direction: DynamicNotchSwipeDirection
    ) -> some View {
        Picker(
            direction.localizedTitle,
            selection: Binding(
                get: {
                    model.current.action(
                        for: rowKind,
                        direction: direction
                    )
                },
                set: { action in
                    model.set(
                        model.current.setting(
                            action,
                            for: rowKind,
                            direction: direction
                        )
                    )
                }
            )
        ) {
            ForEach(DynamicNotchSwipeAction.allCases, id: \.rawValue) {
                action in
                Text(action.localizedTitle).tag(action)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
    }
}

private extension DynamicNotchSwipeRowKind {
    var localizedTitle: String {
        switch self {
        case .notification:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.notification",
                defaultValue: "Notifications"
            )
        case .feed:
            String(
                localized: "settings.notifications.dynamicNotch.swipe.feed",
                defaultValue: "Feed"
            )
        case .unread:
            String(
                localized: "settings.notifications.dynamicNotch.swipe.unread",
                defaultValue: "Unread"
            )
        }
    }

    var localizedSummary: String {
        switch self {
        case .notification:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.notification.subtitle",
                defaultValue:
                    "Runtime notifications created by cmux notify or terminal activity."
            )
        case .feed:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.feed.subtitle",
                defaultValue:
                    "Pending agent approvals, plans, and questions from cmux Feed."
            )
        case .unread:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.unread.subtitle",
                defaultValue: "Unread terminal notifications."
            )
        }
    }
}

private extension DynamicNotchSwipeDirection {
    var localizedTitle: String {
        switch self {
        case .left:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.direction.left",
                defaultValue: "Swipe Left"
            )
        case .right:
            String(
                localized:
                    "settings.notifications.dynamicNotch.swipe.direction.right",
                defaultValue: "Swipe Right"
            )
        }
    }
}

private extension DynamicNotchSwipeAction {
    var localizedTitle: String {
        switch self {
        case .none:
            String(localized: "common.none", defaultValue: "None")
        case .dismiss:
            String(
                localized: "notification.dynamicNotch.dismiss",
                defaultValue: "Dismiss"
            )
        case .hide:
            String(
                localized: "notification.dynamicNotch.hideFromIsland",
                defaultValue: "Hide from Island"
            )
        case .markRead:
            String(
                localized: "contextMenu.markNotificationRead",
                defaultValue: "Mark as Read"
            )
        case .open:
            String(
                localized: "notification.dynamicNotch.open",
                defaultValue: "Open"
            )
        }
    }
}
