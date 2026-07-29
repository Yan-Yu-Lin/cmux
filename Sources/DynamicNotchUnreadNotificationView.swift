import CmuxSettings
import SwiftUI

struct DynamicNotchUnreadNotificationView: View, Equatable {
    let notification: TerminalNotification
    let appearance: DynamicNotchAppearance
    let open: () -> Void
    let markRead: () -> Void
    let dismiss: () -> Void

    static func == (
        lhs: DynamicNotchUnreadNotificationView,
        rhs: DynamicNotchUnreadNotificationView
    ) -> Bool {
        lhs.notification == rhs.notification
            && lhs.appearance == rhs.appearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.dimension(.rowSpacing)) {
            HStack(alignment: .top, spacing: appearance.dimension(.headerSpacing)) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(
                        size: appearance.dimension(.notificationIconSize),
                        weight: .semibold
                    ))
                    .foregroundStyle(
                        appearance.color(.accentColor, system: .accentColor)
                    )
                    .frame(
                        width: appearance.dimension(.notificationIconFrame),
                        height: appearance.dimension(.notificationIconFrame)
                    )

                VStack(alignment: .leading, spacing: appearance.dimension(.textSpacing)) {
                    Text(notification.title)
                        .font(.headline)
                        .foregroundStyle(
                            appearance.color(.primaryTextColor, system: .primary)
                        )
                        .lineLimit(appearance.integer(.titleLineLimit))
                    if !notification.subtitle.isEmpty {
                        Text(notification.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(
                                appearance.color(
                                    .secondaryTextColor,
                                    system: .secondary
                                )
                            )
                            .lineLimit(appearance.integer(.subtitleLineLimit))
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.callout)
                            .foregroundStyle(
                                appearance.color(
                                    .secondaryTextColor,
                                    system: .secondary
                                )
                            )
                            .lineLimit(appearance.integer(.bodyLineLimit))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    appearance.color(.closeButtonColor, system: .secondary)
                )
                .accessibilityLabel(
                    String(
                        localized: "notification.dynamicNotch.dismiss",
                        defaultValue: "Dismiss"
                    )
                )
            }

            HStack(spacing: appearance.dimension(.actionSpacing)) {
                Spacer(minLength: 0)
                Button(
                    String(
                        localized: "contextMenu.markNotificationRead",
                        defaultValue: "Mark as Read"
                    ),
                    action: markRead
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(
                    String(
                        localized: "notification.dynamicNotch.open",
                        defaultValue: "Open"
                    ),
                    action: open
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, appearance.dimension(.rowHorizontalPadding))
        .padding(.top, appearance.dimension(.rowTopPadding))
        .padding(.bottom, appearance.dimension(.rowBottomPadding))
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(
            "DynamicNotchUnreadNotification.\(notification.id)"
        )
    }
}
