import CmuxSettings
import Foundation

/// Presentation controls that stay attached to a notification while policy
/// hooks rewrite its text or its target follows a moved surface.
struct TerminalNotificationPresentation: Hashable, Sendable {
    enum Delivery: String, Hashable, Sendable {
        case settings
        case system
        case dynamicNotch
    }

    struct Action: Hashable, Sendable {
        let id: String
        let title: String
    }

    struct Input: Hashable, Sendable {
        enum Kind: String, Hashable, Sendable {
            case text
            case secure
        }

        let id: String
        let label: String
        let placeholder: String
        let initialValue: String
        let kind: Kind
    }

    struct SwipeAction: Hashable, Sendable {
        let id: String
        let title: String?
    }

    let delivery: Delivery
    let iconSymbolName: String?
    let actions: [Action]
    let inputs: [Input]
    let swipeLeftAction: SwipeAction?
    let swipeRightAction: SwipeAction?
    let appearance: DynamicNotchAppearanceOverrides
    let responseToken: UUID?
    let timeout: TimeInterval

    init(
        delivery: Delivery = .settings,
        iconSymbolName: String? = nil,
        actions: [Action] = [],
        inputs: [Input] = [],
        swipeLeftAction: SwipeAction? = nil,
        swipeRightAction: SwipeAction? = nil,
        appearance: DynamicNotchAppearanceOverrides = DynamicNotchAppearanceOverrides(),
        responseToken: UUID? = nil,
        timeout: TimeInterval = 8
    ) {
        self.delivery = delivery
        self.iconSymbolName = iconSymbolName
        self.actions = actions
        self.inputs = inputs
        self.swipeLeftAction = swipeLeftAction
        self.swipeRightAction = swipeRightAction
        self.appearance = appearance
        self.responseToken = responseToken
        self.timeout = timeout
    }
}
