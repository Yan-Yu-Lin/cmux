import Foundation

/// A gesture direction as observed by the user on a Dynamic Notch row.
public enum DynamicNotchSwipeDirection: String, CaseIterable, Sendable {
    case left
    case right
}

/// The built-in operation assigned to a Dynamic Notch row swipe.
public enum DynamicNotchSwipeAction: String, CaseIterable, Sendable {
    case none
    case dismiss
    case hide
    case markRead
    case open
}

/// The kind of row receiving a Dynamic Notch swipe.
public enum DynamicNotchSwipeRowKind: String, CaseIterable, Sendable {
    case notification
    case feed
    case unread
}

/// Validated, agent-editable defaults for both swipe directions on every row
/// kind. Per-notification runtime overrides take precedence over these values.
public struct DynamicNotchSwipeActions: SettingCodable, Sendable, Equatable {
    private static let keySeparator = "."
    private var values: [String: DynamicNotchSwipeAction]

    public init() {
        values = [
            Self.key(.notification, .left): .dismiss,
            Self.key(.notification, .right): .open,
            Self.key(.feed, .left): .hide,
            Self.key(.feed, .right): .open,
            Self.key(.unread, .left): .markRead,
            Self.key(.unread, .right): .open,
        ]
    }

    private init(values: [String: DynamicNotchSwipeAction]) {
        self.values = values
    }

    public func action(
        for rowKind: DynamicNotchSwipeRowKind,
        direction: DynamicNotchSwipeDirection
    ) -> DynamicNotchSwipeAction {
        values[Self.key(rowKind, direction)]
            ?? DynamicNotchSwipeActions().values[Self.key(rowKind, direction)]
            ?? .none
    }

    public func setting(
        _ action: DynamicNotchSwipeAction,
        for rowKind: DynamicNotchSwipeRowKind,
        direction: DynamicNotchSwipeDirection
    ) -> DynamicNotchSwipeActions {
        var result = self
        result.values[Self.key(rowKind, direction)] = action
        return result
    }

    public func resetting(
        rowKind: DynamicNotchSwipeRowKind? = nil
    ) -> DynamicNotchSwipeActions {
        guard let rowKind else { return DynamicNotchSwipeActions() }
        var result = self
        let defaults = DynamicNotchSwipeActions()
        for direction in DynamicNotchSwipeDirection.allCases {
            result.values[Self.key(rowKind, direction)] =
                defaults.action(for: rowKind, direction: direction)
        }
        return result
    }

    public static func decodeFromUserDefaults(
        _ raw: Any?
    ) -> DynamicNotchSwipeActions? {
        guard let dictionary = raw as? [String: String] else { return nil }
        return decoded(flatValues: dictionary)
    }

    public func encodeForUserDefaults() -> Any {
        values.mapValues(\.rawValue)
    }

    public static func decodeFromJSON(
        _ raw: Any?
    ) -> DynamicNotchSwipeActions? {
        guard let object = raw as? [String: Any] else { return nil }
        var flattened: [String: String] = [:]
        for rowKind in DynamicNotchSwipeRowKind.allCases {
            guard let rawDirections = object[rowKind.rawValue]
                    as? [String: Any] else {
                return nil
            }
            guard Set(rawDirections.keys)
                == Set(DynamicNotchSwipeDirection.allCases.map(\.rawValue))
            else {
                return nil
            }
            for direction in DynamicNotchSwipeDirection.allCases {
                guard let action = rawDirections[direction.rawValue]
                        as? String else {
                    return nil
                }
                flattened[Self.key(rowKind, direction)] = action
            }
        }
        guard Set(object.keys)
                == Set(DynamicNotchSwipeRowKind.allCases.map(\.rawValue))
        else {
            return nil
        }
        return decoded(flatValues: flattened)
    }

    public func encodeForJSON() -> Any {
        Dictionary(
            uniqueKeysWithValues: DynamicNotchSwipeRowKind.allCases.map {
                rowKind in
                (
                    rowKind.rawValue,
                    Dictionary(
                        uniqueKeysWithValues:
                            DynamicNotchSwipeDirection.allCases.map {
                                direction in
                                (
                                    direction.rawValue,
                                    action(
                                        for: rowKind,
                                        direction: direction
                                    ).rawValue
                                )
                            }
                    )
                )
            }
        )
    }

    private static func decoded(
        flatValues: [String: String]
    ) -> DynamicNotchSwipeActions? {
        let expectedKeys = Set(
            DynamicNotchSwipeRowKind.allCases.flatMap { rowKind in
                DynamicNotchSwipeDirection.allCases.map {
                    key(rowKind, $0)
                }
            }
        )
        guard Set(flatValues.keys) == expectedKeys else { return nil }
        var parsed: [String: DynamicNotchSwipeAction] = [:]
        parsed.reserveCapacity(flatValues.count)
        for (key, rawAction) in flatValues {
            guard let action = DynamicNotchSwipeAction(
                rawValue: rawAction
            ) else {
                return nil
            }
            parsed[key] = action
        }
        return DynamicNotchSwipeActions(values: parsed)
    }

    private static func key(
        _ rowKind: DynamicNotchSwipeRowKind,
        _ direction: DynamicNotchSwipeDirection
    ) -> String {
        rowKind.rawValue + keySeparator + direction.rawValue
    }
}
