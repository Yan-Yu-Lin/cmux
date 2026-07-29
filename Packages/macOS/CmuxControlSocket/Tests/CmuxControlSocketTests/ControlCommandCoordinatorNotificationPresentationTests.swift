import Foundation
import Testing
import CmuxSettings
@testable import CmuxControlSocket

@MainActor
private final class FakeNotificationPresentationContext: ControlCommandContext {
    let workspaceID = UUID()
    let surfaceID = UUID()
    var capturedPresentation: ControlNotificationPresentation?
    var createCallCount = 0
    var existingNotifications: [ControlNotificationSnapshot] = []
    var dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
        enabled: false,
        horizontalPosition: 0.5,
        swipeActions: [
            .init(rowKind: "notification", left: "dismiss", right: "open"),
            .init(rowKind: "feed", left: "hide", right: "open"),
            .init(rowKind: "unread", left: "markRead", right: "open"),
        ]
    )
    var configuredDynamicNotchEnabled: Bool?
    var configuredDynamicNotchPosition: Double?
    var configuredDynamicNotchDisplayKey: String?
    var configuredDynamicNotchReset = false
    var configuredDynamicNotchWidth: Double?
    var configuredDynamicNotchHeight: Double?
    var configuredDynamicNotchResetSize = false
    var configuredDynamicNotchSwipeRowKind: String?
    var configuredDynamicNotchSwipeDirection: String?
    var configuredDynamicNotchSwipeAction: String?
    var configuredDynamicNotchResetSwipes = false
    var presentedDynamicNotchPhase: String?
    var presentedDynamicNotchSection: String?
    var presentedDynamicNotchDisplayKey: String?
    var acceptsDynamicNotchPresentation = true

    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String,
        presentation: ControlNotificationPresentation
    ) -> ControlNotificationCreateResolution {
        createCallCount += 1
        capturedPresentation = presentation
        return .delivered(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    func controlNotificationList() -> [ControlNotificationSnapshot] {
        existingNotifications
    }

    func controlDynamicNotchSettings()
        -> ControlDynamicNotchSettingsSnapshot {
        dynamicNotchSettings
    }

    func controlDynamicNotchConfigure(
        enabled: Bool?,
        horizontalPosition: Double?,
        displayKey: String?,
        resetDisplayPosition: Bool,
        expandedWidth: Double?,
        expandedHeight: Double?,
        resetDisplaySize: Bool,
        swipeRowKind: String?,
        swipeDirection: String?,
        swipeAction: String?,
        resetSwipeActions: Bool
    ) -> ControlDynamicNotchSettingsSnapshot {
        configuredDynamicNotchEnabled = enabled
        configuredDynamicNotchPosition = horizontalPosition
        configuredDynamicNotchDisplayKey = displayKey
        configuredDynamicNotchReset = resetDisplayPosition
        configuredDynamicNotchWidth = expandedWidth
        configuredDynamicNotchHeight = expandedHeight
        configuredDynamicNotchResetSize = resetDisplaySize
        configuredDynamicNotchSwipeRowKind = swipeRowKind
        configuredDynamicNotchSwipeDirection = swipeDirection
        configuredDynamicNotchSwipeAction = swipeAction
        configuredDynamicNotchResetSwipes = resetSwipeActions
        var swipes = dynamicNotchSettings.swipeActions
        if resetSwipeActions {
            let defaults = [
                ControlDynamicNotchSwipeSnapshot(
                    rowKind: "notification",
                    left: "dismiss",
                    right: "open"
                ),
                ControlDynamicNotchSwipeSnapshot(
                    rowKind: "feed",
                    left: "hide",
                    right: "open"
                ),
                ControlDynamicNotchSwipeSnapshot(
                    rowKind: "unread",
                    left: "markRead",
                    right: "open"
                ),
            ]
            if let swipeRowKind {
                if let replacement = defaults.first(where: {
                    $0.rowKind == swipeRowKind
                }), let index = swipes.firstIndex(where: {
                    $0.rowKind == swipeRowKind
                }) {
                    swipes[index] = replacement
                }
            } else {
                swipes = defaults
            }
        } else if let swipeRowKind,
                  let swipeDirection,
                  let swipeAction,
                  let index = swipes.firstIndex(where: {
                      $0.rowKind == swipeRowKind
                  }) {
            let current = swipes[index]
            swipes[index] = ControlDynamicNotchSwipeSnapshot(
                rowKind: swipeRowKind,
                left:
                    swipeDirection == "left"
                        ? swipeAction : current.left,
                right:
                    swipeDirection == "right"
                        ? swipeAction : current.right
            )
        }
        dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
            enabled: enabled ?? dynamicNotchSettings.enabled,
            horizontalPosition:
                displayKey == nil
                    ? horizontalPosition
                        ?? dynamicNotchSettings.horizontalPosition
                    : dynamicNotchSettings.horizontalPosition,
            expandedWidth:
                displayKey == nil
                    ? expandedWidth ?? dynamicNotchSettings.expandedWidth
                    : dynamicNotchSettings.expandedWidth,
            expandedHeight:
                displayKey == nil
                    ? expandedHeight ?? dynamicNotchSettings.expandedHeight
                    : dynamicNotchSettings.expandedHeight,
            swipeActions: swipes,
            displays: dynamicNotchSettings.displays
        )
        return dynamicNotchSettings
    }

    func controlDynamicNotchPresent(
        phase: String,
        section: String?,
        displayKey: String?
    ) -> Bool {
        presentedDynamicNotchPhase = phase
        presentedDynamicNotchSection = section
        presentedDynamicNotchDisplayKey = displayKey
        return acceptsDynamicNotchPresentation
    }
}

@MainActor
@Suite("ControlCommandCoordinator notification presentation")
struct ControlCommandCoordinatorNotificationPresentationTests {
    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "notification.create", params: params)
    }

    @Test func defaultPresentationPreservesLegacyNotificationBehavior() {
        let presentation = ControlNotificationPresentation()

        #expect(presentation.delivery == .settings)
        #expect(presentation.iconSymbolName == nil)
        #expect(presentation.actions.isEmpty)
        #expect(presentation.inputs.isEmpty)
        #expect(presentation.responseToken == nil)
        #expect(presentation.timeout == 8)
    }

    @Test func dynamicFormCrossesTheControlSeamWithoutLosingCallerData() throws {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let notificationID = UUID()
        let responseToken = UUID()

        let result = coordinator.handle(request([
            "notification_id": .string(notificationID.uuidString),
            "delivery": .string("dynamicNotch"),
            "icon": .string("hand.raised.fill"),
            "actions": .array([
                .object(["id": .string("approve"), "title": .string("Approve")]),
                .object(["id": .string("deny"), "title": .string("Deny")]),
            ]),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "placeholder": .string("Optional note"),
                    "initial_value": .string("Looks good"),
                    "secure": .bool(false),
                ]),
                .object([
                    "id": .string("token"),
                    "label": .string("Token"),
                    "secure": .bool(true),
                ]),
            ]),
            "appearance": .object([
                "expandedWidth": .int(620),
                "accentColor": .string("#0A84FF"),
                "showScrollIndicators": .bool(false),
            ]),
            "response_token": .string(responseToken.uuidString),
            "timeout": .double(120),
        ]))

        #expect(result == .ok(.object([
            "id": .string(notificationID.uuidString),
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
        ])))
        #expect(context.capturedPresentation == ControlNotificationPresentation(
            notificationID: notificationID,
            delivery: .dynamicNotch,
            iconSymbolName: "hand.raised.fill",
            actions: [
                .init(id: "approve", title: "Approve"),
                .init(id: "deny", title: "Deny"),
            ],
            inputs: [
                .init(
                    id: "reason",
                    label: "Reason",
                    placeholder: "Optional note",
                    initialValue: "Looks good",
                    kind: .text
                ),
                .init(
                    id: "token",
                    label: "Token",
                    placeholder: "",
                    initialValue: "",
                    kind: .secure
                ),
            ],
            appearance: try DynamicNotchAppearanceOverrides(jsonObject: [
                "expandedWidth": 620,
                "accentColor": "#0A84FF",
                "showScrollIndicators": false,
            ]),
            responseToken: responseToken,
            timeout: 120
        ))
    }

    @Test func ordinaryCreateKeepsSettingsDeliveryAndGeneratesAnIdentifier() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(["title": .string("Done")]))

        guard let presentation = context.capturedPresentation else {
            Issue.record("notification.create did not reach the context")
            return
        }
        #expect(presentation.delivery == .settings)
        #expect(presentation.actions.isEmpty)
        #expect(presentation.inputs.isEmpty)
        #expect(presentation.timeout == 8)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("notification.create returned an error")
            return
        }
        #expect(payload["id"] == .string(presentation.notificationID.uuidString))
    }

    @Test func callerSuppliedActiveNotificationIDIsRejected() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let notificationID = UUID()
        context.existingNotifications = [
            ControlNotificationSnapshot(
                id: notificationID,
                workspaceID: UUID(),
                surfaceID: nil,
                title: "Existing",
                subtitle: "",
                body: "",
                createdAtISO8601: "2026-01-01T00:00:00Z",
                isRead: false,
                tabTitle: nil
            ),
        ]

        let result = coordinator.handle(request([
            "notification_id": .string(notificationID.uuidString),
            "title": .string("Duplicate"),
        ]))

        #expect(result == .err(
            code: "invalid_params",
            message: "invalid notification presentation",
            data: nil
        ))
        #expect(context.createCallCount == 0)
    }

    @Test(arguments: [
        [
            "delivery": JSONValue.string("system"),
            "actions": .array([
                .object(["id": .string("approve"), "title": .string("Approve")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object(["id": .string("open"), "title": .string("Override built-in")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "secure": .string("yes"),
                ]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object(["id": .string("../reason"), "label": .string("Reason")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object(["id": .string("承認"), "title": .string("Approve")]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "actions": .array([
                .object([
                    "id": .string("approve"),
                    "title": .string("Approve"),
                    "command": .string("deploy"),
                ]),
            ]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "timeout": .bool(true),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "inputs": .array([
                .object([
                    "id": .string("reason"),
                    "label": .string("Reason"),
                    "placeholder": .int(42),
                ]),
            ]),
        ],
        [
            "delivery": JSONValue.string("system"),
            "appearance": .object(["expandedWidth": .int(620)]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "appearance": .object(["expandedWidth": .int(299)]),
        ],
        [
            "delivery": JSONValue.string("dynamicNotch"),
            "appearance": .object(["unknown": .int(1)]),
        ],
    ])
    func malformedOrUnsafeFormsAreRejectedBeforeAppMutation(
        params: [String: JSONValue]
    ) {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(params))

        #expect(result == .err(
            code: "invalid_params",
            message: "invalid notification presentation",
            data: nil
        ))
        #expect(context.createCallCount == 0)
    }

    @Test func dynamicNotchSettingsAreReadableAndConfigurable() {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let initial = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "notification.dynamic_notch.settings",
                params: [:]
            )
        )
        #expect(initial == .ok(.object([
            "enabled": .bool(false),
            "delivery": .string("system"),
            "horizontal_position": .double(0.5),
            "expanded_width": .double(460),
            "expanded_height": .double(520),
            "swipe_actions": .object([
                "notification": .object([
                    "left": .string("dismiss"),
                    "right": .string("open"),
                ]),
                "feed": .object([
                    "left": .string("hide"),
                    "right": .string("open"),
                ]),
                "unread": .object([
                    "left": .string("markRead"),
                    "right": .string("open"),
                ]),
            ]),
            "displays": .array([]),
        ])))

        let configured = coordinator.handle(
            ControlRequest(
                id: .int(2),
                method: "notification.dynamic_notch.configure",
                params: [
                    "enabled": .bool(true),
                    "horizontal_position": .double(0.25),
                    "expanded_width": .double(680),
                    "expanded_height": .double(640),
                    "swipe_row_kind": .string("feed"),
                    "swipe_direction": .string("left"),
                    "swipe_action": .string("dismiss"),
                ]
            )
        )
        #expect(context.configuredDynamicNotchEnabled == true)
        #expect(context.configuredDynamicNotchPosition == 0.25)
        #expect(context.configuredDynamicNotchWidth == 680)
        #expect(context.configuredDynamicNotchHeight == 640)
        #expect(context.configuredDynamicNotchSwipeRowKind == "feed")
        #expect(context.configuredDynamicNotchSwipeDirection == "left")
        #expect(context.configuredDynamicNotchSwipeAction == "dismiss")
        #expect(configured == .ok(.object([
            "enabled": .bool(true),
            "delivery": .string("dynamicNotch"),
            "horizontal_position": .double(0.25),
            "expanded_width": .double(680),
            "expanded_height": .double(640),
            "swipe_actions": .object([
                "notification": .object([
                    "left": .string("dismiss"),
                    "right": .string("open"),
                ]),
                "feed": .object([
                    "left": .string("dismiss"),
                    "right": .string("open"),
                ]),
                "unread": .object([
                    "left": .string("markRead"),
                    "right": .string("open"),
                ]),
            ]),
            "displays": .array([]),
        ])))
    }

    @Test func dynamicNotchPositionCanTargetOneDisplay() {
        let context = FakeNotificationPresentationContext()
        context.dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
            enabled: true,
            horizontalPosition: 0.5,
            displays: [
                ControlDynamicNotchDisplaySnapshot(
                    key: "uuid:external",
                    id: 42,
                    name: "Studio Display",
                    hasHardwareNotch: false,
                    horizontalPosition: 0.7,
                    hasPositionOverride: true
                ),
            ]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(3),
                method: "notification.dynamic_notch.configure",
                params: [
                    "horizontal_position": .double(0.3),
                    "display_key": .string("uuid:external"),
                ]
            )
        )

        #expect(context.configuredDynamicNotchPosition == 0.3)
        #expect(
            context.configuredDynamicNotchDisplayKey == "uuid:external"
        )
        #expect(!context.configuredDynamicNotchReset)
        guard case .ok(.object(let payload)) = result,
              case .array(let displays) = payload["displays"] else {
            Issue.record("Expected a display settings payload")
            return
        }
        #expect(displays.count == 1)
    }

    @Test func dynamicNotchPresentationCanSelectUnreadOnOneDisplay() {
        let context = FakeNotificationPresentationContext()
        context.dynamicNotchSettings = ControlDynamicNotchSettingsSnapshot(
            enabled: true,
            horizontalPosition: 0.5
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(4),
                method: "notification.dynamic_notch.present",
                params: [
                    "phase": .string("expanded"),
                    "section": .string("unread"),
                    "display_key": .string("uuid:external"),
                ]
            )
        )

        #expect(context.presentedDynamicNotchPhase == "expanded")
        #expect(context.presentedDynamicNotchSection == "unread")
        #expect(
            context.presentedDynamicNotchDisplayKey == "uuid:external"
        )
        guard case .ok(.object(let payload)) = result else {
            Issue.record("Expected a Dynamic Notch presentation payload")
            return
        }
        #expect(payload["phase"] == .string("expanded"))
        #expect(payload["section"] == .string("unread"))
        #expect(payload["display_key"] == .string("uuid:external"))
    }

    @Test(arguments: [
        ["phase": JSONValue.string("large")],
        [
            "phase": JSONValue.string("expanded"),
            "section": JSONValue.string("notifications"),
        ],
        [
            "phase": JSONValue.string("expanded"),
            "display_key": JSONValue.string(""),
        ],
    ])
    func invalidDynamicNotchPresentationIsRejected(
        params: [String: JSONValue]
    ) {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(5),
                method: "notification.dynamic_notch.present",
                params: params
            )
        )

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid presentation to fail")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.presentedDynamicNotchPhase == nil)
    }

    @Test(arguments: [
        ["enabled": JSONValue.string("yes")],
        ["horizontal_position": JSONValue.bool(true)],
        ["horizontal_position": JSONValue.double(-0.01)],
        ["horizontal_position": JSONValue.double(1.01)],
        ["expanded_width": JSONValue.double(299)],
        ["expanded_height": JSONValue.double(1_401)],
        [
            "display_key": JSONValue.string("uuid:external"),
            "expanded_width": JSONValue.double(680),
        ],
        ["reset_display_size": JSONValue.bool(true)],
        ["swipe_row_kind": JSONValue.string("feed")],
        [
            "swipe_row_kind": JSONValue.string("unknown"),
            "swipe_direction": JSONValue.string("left"),
            "swipe_action": JSONValue.string("hide"),
        ],
        [
            "swipe_row_kind": JSONValue.string("feed"),
            "swipe_direction": JSONValue.string("up"),
            "swipe_action": JSONValue.string("hide"),
        ],
        [
            "swipe_row_kind": JSONValue.string("feed"),
            "swipe_direction": JSONValue.string("left"),
            "swipe_action": JSONValue.string("launch"),
        ],
        ["display_key": JSONValue.string("uuid:external")],
        [
            "display_key": JSONValue.string("uuid:external"),
            "reset_display_position": JSONValue.bool(true),
            "horizontal_position": JSONValue.double(0.5),
        ],
        ["reset_display_position": JSONValue.bool(true)],
        [:],
    ])
    func invalidDynamicNotchConfigurationIsRejected(
        params: [String: JSONValue]
    ) {
        let context = FakeNotificationPresentationContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "notification.dynamic_notch.configure",
                params: params
            )
        )

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.configuredDynamicNotchEnabled == nil)
        #expect(context.configuredDynamicNotchPosition == nil)
        #expect(context.configuredDynamicNotchDisplayKey == nil)
        #expect(!context.configuredDynamicNotchReset)
    }
}
