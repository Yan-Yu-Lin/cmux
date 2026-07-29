/// Agent-facing Dynamic Notch defaults returned by the control socket.
public struct ControlDynamicNotchSettingsSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let horizontalPosition: Double
    public let expandedWidth: Double
    public let expandedHeight: Double
    public let swipeActions: [ControlDynamicNotchSwipeSnapshot]
    public let displays: [ControlDynamicNotchDisplaySnapshot]

    public init(
        enabled: Bool,
        horizontalPosition: Double,
        expandedWidth: Double = 460,
        expandedHeight: Double = 520,
        swipeActions: [ControlDynamicNotchSwipeSnapshot] = [],
        displays: [ControlDynamicNotchDisplaySnapshot] = []
    ) {
        self.enabled = enabled
        self.horizontalPosition = horizontalPosition
        self.expandedWidth = expandedWidth
        self.expandedHeight = expandedHeight
        self.swipeActions = swipeActions
        self.displays = displays
    }
}

/// Resolved gesture defaults for one Dynamic Notch row kind.
public struct ControlDynamicNotchSwipeSnapshot: Equatable, Sendable {
    public let rowKind: String
    public let left: String
    public let right: String

    public init(rowKind: String, left: String, right: String) {
        self.rowKind = rowKind
        self.left = left
        self.right = right
    }
}

/// One connected display and its resolved Dynamic Notch placement.
public struct ControlDynamicNotchDisplaySnapshot: Equatable, Sendable {
    public let key: String
    public let id: UInt32?
    public let name: String
    public let hasHardwareNotch: Bool
    public let horizontalPosition: Double
    public let hasPositionOverride: Bool
    public let expandedWidth: Double
    public let expandedHeight: Double
    public let hasSizeOverride: Bool

    public init(
        key: String,
        id: UInt32?,
        name: String,
        hasHardwareNotch: Bool,
        horizontalPosition: Double,
        hasPositionOverride: Bool,
        expandedWidth: Double = 460,
        expandedHeight: Double = 520,
        hasSizeOverride: Bool = false
    ) {
        self.key = key
        self.id = id
        self.name = name
        self.hasHardwareNotch = hasHardwareNotch
        self.horizontalPosition = horizontalPosition
        self.hasPositionOverride = hasPositionOverride
        self.expandedWidth = expandedWidth
        self.expandedHeight = expandedHeight
        self.hasSizeOverride = hasSizeOverride
    }
}
