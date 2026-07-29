import AppKit
import CmuxSettings
import SwiftUI

struct DynamicNotchSwipeActionDescriptor: Equatable {
    let id: String
    let title: String
    let symbolName: String
    let background: Color
    let foreground: Color
}

/// Horizontal trackpad/mouse swipe interaction that coexists with the
/// enclosing vertical ScrollView. Rows are translated without rebuilding the
/// list, and the action commits only after a directional threshold.
struct DynamicNotchSwipeContainer<Content: View>: View {
    let leftAction: DynamicNotchSwipeActionDescriptor?
    let rightAction: DynamicNotchSwipeActionDescriptor?
    let perform: (DynamicNotchSwipeActionDescriptor) -> Void
    @ViewBuilder let content: () -> Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var tracksHorizontally = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            actionBackground
            content()
                .offset(x: horizontalOffset)
        }
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(swipeGesture)
        .accessibilityAction(
            named: Text(
                leftAction?.title
                    ?? String(localized: "common.none", defaultValue: "None")
            )
        ) {
            if let leftAction {
                perform(leftAction)
            }
        }
    }

    @ViewBuilder
    private var actionBackground: some View {
        if horizontalOffset < 0, let leftAction {
            swipeLabel(leftAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(leftAction.background)
        } else if horizontalOffset > 0, let rightAction {
            swipeLabel(rightAction)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rightAction.background)
        }
    }

    private func swipeLabel(
        _ action: DynamicNotchSwipeActionDescriptor
    ) -> some View {
        Label(action.title, systemImage: action.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(action.foreground)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !tracksHorizontally {
                    guard abs(value.translation.width)
                            > abs(value.translation.height) * 1.15 else {
                        return
                    }
                    tracksHorizontally = true
                }
                let translation = value.translation.width
                guard translation < 0 && leftAction != nil
                        || translation > 0 && rightAction != nil else {
                    horizontalOffset = translation * 0.12
                    return
                }
                horizontalOffset = translation
            }
            .onEnded { value in
                defer { tracksHorizontally = false }
                guard tracksHorizontally else {
                    horizontalOffset = 0
                    return
                }
                let projected = value.predictedEndTranslation.width
                let commitsLeft = horizontalOffset < -72 || projected < -120
                let commitsRight = horizontalOffset > 72 || projected > 120
                if commitsLeft, let leftAction {
                    commit(leftAction, edgeOffset: -520)
                } else if commitsRight, let rightAction {
                    commit(rightAction, edgeOffset: 520)
                } else {
                    resetOffset()
                }
            }
    }

    private func commit(
        _ action: DynamicNotchSwipeActionDescriptor,
        edgeOffset: CGFloat
    ) {
        if reduceMotion {
            horizontalOffset = 0
            perform(action)
            return
        }
        withAnimation(.snappy(duration: 0.18)) {
            horizontalOffset = edgeOffset
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            perform(action)
            horizontalOffset = 0
        }
    }

    private func resetOffset() {
        if reduceMotion {
            horizontalOffset = 0
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                horizontalOffset = 0
            }
        }
    }
}

extension DynamicNotchSwipeAction {
    var dynamicNotchTitle: String {
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

    var dynamicNotchSymbolName: String {
        switch self {
        case .none:
            "minus"
        case .dismiss:
            "xmark"
        case .hide:
            "eye.slash"
        case .markRead:
            "checkmark.circle"
        case .open:
            "arrow.up.right"
        }
    }
}
