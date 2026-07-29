import CMUXAgentLaunch
import SwiftUI

/// Reuses the Feed card and its existing approval/question/textbox actions with
/// an immutable row snapshot.
struct DynamicNotchFeedItemView: View, Equatable {
    let item: WorkstreamItem
    let open: () -> Void

    @State private var stopDraft = FeedStopDraft()
    @State private var stopFocusRequest = 0

    static func == (
        lhs: DynamicNotchFeedItemView,
        rhs: DynamicNotchFeedItemView
    ) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        FeedItemRow(
            snapshot: FeedItemSnapshot(item: item),
            actions: FeedRowActions.bound(),
            isSelected: false,
            onPressSelect: {},
            onControlFocus: {},
            onControlAction: {},
            onControlBlur: {},
            onActivate: open,
            stopDraft: $stopDraft,
            stopDraftValue: stopDraft,
            stopFocusRequest: $stopFocusRequest,
            stopFocusRequestValue: stopFocusRequest
        )
        .equatable()
        .accessibilityIdentifier("DynamicNotchFeedItem.\(item.id)")
    }
}
