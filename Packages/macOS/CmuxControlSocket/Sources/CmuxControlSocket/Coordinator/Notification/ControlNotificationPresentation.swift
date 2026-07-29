public import CmuxSettings
public import Foundation

/// Validated, app-independent presentation controls for a notification create
/// request. The app maps this value to its concrete presentation model.
public struct ControlNotificationPresentation: Sendable, Equatable {
    private enum ParseError: Error {
        case invalid
    }

    public enum Delivery: String, Sendable {
        case settings
        case system
        case dynamicNotch
    }

    public struct Action: Sendable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Input: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case text
            case secure
        }

        public let id: String
        public let label: String
        public let placeholder: String
        public let initialValue: String
        public let kind: Kind

        public init(
            id: String,
            label: String,
            placeholder: String,
            initialValue: String,
            kind: Kind
        ) {
            self.id = id
            self.label = label
            self.placeholder = placeholder
            self.initialValue = initialValue
            self.kind = kind
        }
    }

    public struct SwipeAction: Sendable, Equatable {
        public let id: String
        public let title: String?

        public init(id: String, title: String? = nil) {
            self.id = id
            self.title = title
        }
    }

    public let notificationID: UUID
    public let delivery: Delivery
    public let iconSymbolName: String?
    public let actions: [Action]
    public let inputs: [Input]
    public let swipeLeftAction: SwipeAction?
    public let swipeRightAction: SwipeAction?
    public let appearance: DynamicNotchAppearanceOverrides
    public let responseToken: UUID?
    public let timeout: TimeInterval

    public init(
        notificationID: UUID = UUID(),
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
        self.notificationID = notificationID
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

    /// Parses and validates the presentation fields accepted by every
    /// notification creation entrypoint.
    public init?(parameters: [String: JSONValue]) {
        do {
            let notificationID = try Self.parseNotificationID(parameters)
            let delivery = try Self.parseDelivery(parameters)
            let icon = try Self.parseIcon(parameters)
            let actions = try Self.parseActions(parameters)
            let inputs = try Self.parseInputs(parameters)
            let swipeActions = try Self.parseSwipeActions(
                parameters,
                actions: actions
            )
            let appearance = try Self.parseAppearance(parameters)
            let responseToken = try Self.parseResponseToken(parameters)
            let timeout = try Self.parseTimeout(parameters)
            guard (actions.isEmpty
                    && inputs.isEmpty
                    && swipeActions.left == nil
                    && swipeActions.right == nil
                    && appearance.isEmpty
                    && responseToken == nil)
                    || delivery == .dynamicNotch else {
                return nil
            }
            self.init(
                notificationID: notificationID,
                delivery: delivery,
                iconSymbolName: icon,
                actions: actions,
                inputs: inputs,
                swipeLeftAction: swipeActions.left,
                swipeRightAction: swipeActions.right,
                appearance: appearance,
                responseToken: responseToken,
                timeout: timeout
            )
        } catch {
            return nil
        }
    }

    private static func parseNotificationID(
        _ parameters: [String: JSONValue]
    ) throws -> UUID {
        guard let value = parameters["notification_id"] else { return UUID() }
        guard case .string(let rawValue) = value,
              let notificationID = UUID(uuidString: rawValue) else {
            throw ParseError.invalid
        }
        return notificationID
    }

    private static func parseDelivery(
        _ parameters: [String: JSONValue]
    ) throws -> Delivery {
        let rawValue: String
        if let value = parameters["delivery"] {
            guard case .string(let string) = value else { throw ParseError.invalid }
            rawValue = string
        } else {
            rawValue = "settings"
        }
        switch rawValue {
        case "settings", "default":
            return .settings
        case "system":
            return .system
        case "dynamicNotch", "notch":
            return .dynamicNotch
        default:
            throw ParseError.invalid
        }
    }

    private static func parseIcon(
        _ parameters: [String: JSONValue]
    ) throws -> String? {
        guard let value = parameters["icon"] else { return nil }
        guard case .string(let rawValue) = value else { throw ParseError.invalid }
        let icon = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard icon.count <= 128 else { throw ParseError.invalid }
        return icon.isEmpty ? nil : icon
    }

    private static func parseActions(
        _ parameters: [String: JSONValue]
    ) throws -> [Action] {
        guard let value = parameters["actions"] else { return [] }
        guard case .array(let rawActions) = value,
              rawActions.count <= 4 else {
            throw ParseError.invalid
        }
        var actions: [Action] = []
        var actionIDs: Set<String> = []
        let reservedIDs: Set<String> = [
            "open", "dismiss", "timeout", "replaced", "dismissed",
        ]
        for rawAction in rawActions {
            guard case .object(let object) = rawAction,
                  Set(object.keys).isSubset(of: ["id", "title"]),
                  case .string(let rawID)? = object["id"],
                  case .string(let rawTitle)? = object["title"] else {
                throw ParseError.invalid
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  id.count <= 64,
                  !title.isEmpty,
                  title.count <= 80,
                  !reservedIDs.contains(id),
                  controlIdentifierIsValid(id),
                  actionIDs.insert(id).inserted else {
                throw ParseError.invalid
            }
            actions.append(Action(id: id, title: title))
        }
        return actions
    }

    private static func parseInputs(
        _ parameters: [String: JSONValue]
    ) throws -> [Input] {
        guard let value = parameters["inputs"] else { return [] }
        guard case .array(let rawInputs) = value,
              rawInputs.count <= 4 else {
            throw ParseError.invalid
        }
        var inputs: [Input] = []
        var inputIDs: Set<String> = []
        for rawInput in rawInputs {
            guard case .object(let object) = rawInput,
                  Set(object.keys).isSubset(of: [
                      "id", "label", "placeholder", "initial_value", "secure",
                  ]),
                  case .string(let rawID)? = object["id"],
                  case .string(let rawLabel)? = object["label"] else {
                throw ParseError.invalid
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let placeholder = try optionalString(object["placeholder"]) ?? ""
            let initialValue = try optionalString(object["initial_value"]) ?? ""
            let kind: Input.Kind
            switch object["secure"] {
            case .bool(true)?:
                kind = .secure
            case .bool(false)?, nil:
                kind = .text
            default:
                throw ParseError.invalid
            }
            guard !id.isEmpty,
                  id.count <= 64,
                  controlIdentifierIsValid(id),
                  inputIDs.insert(id).inserted,
                  !label.isEmpty,
                  label.count <= 80,
                  placeholder.count <= 160,
                  initialValue.count <= 4_096 else {
                throw ParseError.invalid
            }
            inputs.append(Input(
                id: id,
                label: label,
                placeholder: placeholder,
                initialValue: initialValue,
                kind: kind
            ))
        }
        return inputs
    }

    private static func parseSwipeActions(
        _ parameters: [String: JSONValue],
        actions: [Action]
    ) throws -> (left: SwipeAction?, right: SwipeAction?) {
        guard let value = parameters["swipe_actions"] else {
            return (nil, nil)
        }
        guard case .object(let object) = value,
            Set(object.keys).isSubset(of: ["left", "right"])
        else {
            throw ParseError.invalid
        }
        let customActionIDs = Set(actions.map(\.id))
        return (
            try parseSwipeAction(
                object["left"],
                customActionIDs: customActionIDs
            ),
            try parseSwipeAction(
                object["right"],
                customActionIDs: customActionIDs
            )
        )
    }

    private static func parseSwipeAction(
        _ value: JSONValue?,
        customActionIDs: Set<String>
    ) throws -> SwipeAction? {
        guard let value else { return nil }
        if case .null = value { return nil }
        let rawID: String
        let rawTitle: String?
        switch value {
        case .string(let id):
            rawID = id
            rawTitle = nil
        case .object(let object):
            guard Set(object.keys).isSubset(of: ["id", "title"]),
                case .string(let id)? = object["id"]
            else {
                throw ParseError.invalid
            }
            rawID = id
            rawTitle = try optionalString(object["title"])
        default:
            throw ParseError.invalid
        }

        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let builtInIDs = Set([
            "dismiss", "hide", "markRead", "mark-read", "open", "none",
        ])
        guard id.count <= 64,
            controlIdentifierIsValid(id),
            builtInIDs.contains(id) || customActionIDs.contains(id),
            title?.isEmpty != true,
            (title?.count ?? 0) <= 80
        else {
            throw ParseError.invalid
        }
        return SwipeAction(id: id, title: title)
    }

    private static func parseResponseToken(
        _ parameters: [String: JSONValue]
    ) throws -> UUID? {
        guard let value = parameters["response_token"] else { return nil }
        guard case .string(let rawValue) = value,
              let token = UUID(uuidString: rawValue) else {
            throw ParseError.invalid
        }
        return token
    }

    private static func parseAppearance(
        _ parameters: [String: JSONValue]
    ) throws -> DynamicNotchAppearanceOverrides {
        guard let value = parameters["appearance"] else {
            return DynamicNotchAppearanceOverrides()
        }
        guard case .object = value else {
            throw ParseError.invalid
        }
        do {
            return try DynamicNotchAppearanceOverrides(
                jsonObject: value.foundationObject
            )
        } catch {
            throw ParseError.invalid
        }
    }

    private static func parseTimeout(
        _ parameters: [String: JSONValue]
    ) throws -> TimeInterval {
        let timeout: TimeInterval
        switch parameters["timeout"] {
        case .double(let value)?:
            timeout = value
        case .int(let value)?:
            timeout = Double(value)
        case nil:
            timeout = 8
        default:
            throw ParseError.invalid
        }
        guard timeout.isFinite, (0...86_400).contains(timeout) else {
            throw ParseError.invalid
        }
        return timeout
    }

    private static func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { throw ParseError.invalid }
        return string
    }

    private static func controlIdentifierIsValid(_ identifier: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
    }
}
