import CmuxSettings
import Foundation

extension CMUXCLI {
    func runDynamicNotchCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "status"
        let response: [String: Any]

        switch subcommand {
        case "status":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.settings"
            )
        case "enable", "on":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: ["enabled": true]
            )
        case "disable", "off":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: ["enabled": false]
            )
        case "toggle":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            let current = try client.sendV2(
                method: "notification.dynamic_notch.settings"
            )
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: [
                    "enabled": !((current["enabled"] as? Bool) ?? false)
                ]
            )
        case "show", "open", "expand":
            var arguments = Array(commandArgs.dropFirst())
            let section: String?
            if let first = arguments.first?.lowercased(),
                ["feed", "unread"].contains(first) {
                section = first
                arguments.removeFirst()
            } else {
                section = nil
            }
            let displayKey = try dynamicNotchDisplayKey(
                from: arguments,
                client: client
            )
            var params: [String: Any] = ["phase": "expanded"]
            if let section {
                params["section"] = section
            }
            if let displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.present",
                params: params
            )
        case "compact", "hide", "retract", "auto":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            let phase =
                subcommand == "compact"
                ? "compact"
                : subcommand == "auto"
                    ? "auto"
                    : "retracted"
            var params: [String: Any] = ["phase": phase]
            if let displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.present",
                params: params
            )
        case "position", "set-position":
            let arguments = try dynamicNotchPositionArguments(
                commandArgs,
                client: client
            )
            var params: [String: Any] = [
                "horizontal_position": arguments.position
            ]
            if let displayKey = arguments.displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        case "center":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            var params: [String: Any] = ["horizontal_position": 0.5]
            if let displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        case "reset-position":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            if let displayKey {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: [
                        "display_key": displayKey,
                        "reset_display_position": true,
                    ]
                )
            } else {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: ["horizontal_position": 0.5]
                )
            }
        case "size", "resize":
            let arguments = try dynamicNotchSizeArguments(
                commandArgs,
                client: client
            )
            var params: [String: Any] = [
                "expanded_width": arguments.width,
                "expanded_height": arguments.height,
            ]
            if let displayKey = arguments.displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        case "reset-size":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            if let displayKey {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: [
                        "display_key": displayKey,
                        "reset_display_size": true,
                    ]
                )
            } else {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: [
                        "expanded_width": 460,
                        "expanded_height": 520,
                    ]
                )
            }
        case "swipe":
            guard commandArgs.count == 4,
                let rowKind = DynamicNotchSwipeRowKind(
                    rawValue: commandArgs[1]
                ),
                let direction = DynamicNotchSwipeDirection(
                    rawValue: commandArgs[2]
                )
            else {
                throw dynamicNotchUsageError()
            }
            let normalizedAction =
                commandArgs[3] == "mark-read"
                ? "markRead"
                : commandArgs[3]
            guard let action = DynamicNotchSwipeAction(
                rawValue: normalizedAction
            ) else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: [
                    "swipe_row_kind": rowKind.rawValue,
                    "swipe_direction": direction.rawValue,
                    "swipe_action": action.rawValue,
                ]
            )
        case "reset-swipe":
            guard commandArgs.count == 1 || commandArgs.count == 2 else {
                throw dynamicNotchUsageError()
            }
            var params: [String: Any] = ["reset_swipe_actions": true]
            if commandArgs.count == 2 {
                guard let rowKind = DynamicNotchSwipeRowKind(
                    rawValue: commandArgs[1]
                ) else {
                    throw dynamicNotchUsageError()
                }
                params["swipe_row_kind"] = rowKind.rawValue
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        default:
            throw dynamicNotchUsageError()
        }

        if jsonOutput {
            print(jsonString(response))
            return
        }
        let state =
            (response["enabled"] as? Bool) == true
            ? String(
                localized: "cli.dynamicNotch.state.enabled",
                defaultValue: "enabled"
            )
            : String(
                localized: "cli.dynamicNotch.state.disabled",
                defaultValue: "disabled"
            )
        let statusFormat = String(
            localized: "cli.dynamicNotch.status",
            defaultValue: "Dynamic Notch: %@"
        )
        print(String.localizedStringWithFormat(statusFormat, state))
        if let phase = response["phase"] as? String {
            if let section = response["section"] as? String {
                let presentationFormat = String(
                    localized:
                        "cli.dynamicNotch.presentationWithSection",
                    defaultValue: "Presentation: %@ (%@)"
                )
                print(
                    String.localizedStringWithFormat(
                        presentationFormat,
                        phase,
                        section
                    )
                )
            } else {
                let presentationFormat = String(
                    localized: "cli.dynamicNotch.presentation",
                    defaultValue: "Presentation: %@"
                )
                print(
                    String.localizedStringWithFormat(
                        presentationFormat,
                        phase
                    )
                )
            }
        }

        let position =
            (response["horizontal_position"] as? NSNumber)?
            .doubleValue ?? 0.5
        let positionFormat = String(
            localized: "cli.dynamicNotch.horizontalPosition",
            defaultValue: "Default horizontal position: %.2f"
        )
        print(String.localizedStringWithFormat(positionFormat, position))
        let width =
            (response["expanded_width"] as? NSNumber)?.doubleValue ?? 460
        let height =
            (response["expanded_height"] as? NSNumber)?.doubleValue ?? 520
        let sizeFormat = String(
            localized: "cli.dynamicNotch.expandedSize",
            defaultValue: "Default expanded size: %.0f × %.0f"
        )
        print(
            String.localizedStringWithFormat(
                sizeFormat,
                width,
                height
            )
        )
        printDynamicNotchSwipeActions(response["swipe_actions"])
        printDynamicNotchDisplays(response["displays"])
    }

    func dynamicNotchUsage() -> String {
        String(
            localized: "cli.help.dynamicNotch",
            defaultValue: """
                Usage: cmux dynamic-notch <command> [arguments] [--display <id|name|key>] [--json]

                Control the default interactive Dynamic Notch notification tray.

                Subcommands:
                  status                  Print enablement and every display.
                  enable|on               Use Dynamic Notch for default notifications.
                  disable|off             Use macOS Notification Center by default.
                  toggle                  Toggle the default notification delivery.
                  show [feed|unread] [--display <id|name|key>]
                                          Expand and pin a tray section.
                  compact [--display <id|name|key>]
                                          Show and pin the compact pill.
                  hide [--display <id|name|key>]
                                          Retract the tray.
                  auto [--display <id|name|key>]
                                          Restore pointer-driven presentation.
                  position <0...1>        Set the synthetic notch position.
                  position left|center|right
                                          Set a named synthetic notch position.
                  position <value> --display <id|name|key>
                                          Move one connected display's notch.
                  center [--display <id|name|key>]
                                          Center all displays or one display.
                  reset-position --display <id|name|key>
                                          Restore one display to the global position.
                  size <width> <height> [--display <id|name|key>]
                                          Set the global or per-display expanded viewport.
                  reset-size [--display <id|name|key>]
                                          Restore built-in dimensions globally or remove one override.
                  swipe <notification|feed|unread> <left|right> <none|dismiss|hide|markRead|open>
                                          Assign one directional row action.
                  reset-swipe [notification|feed|unread]
                                          Restore all swipe defaults or one row kind.

                Explicit `cmux notify --delivery notch` calls still show the tray
                when its default delivery is disabled.
                """
        )
    }

    private func dynamicNotchPosition(_ raw: String) throws -> Double {
        switch raw.lowercased() {
        case "left":
            return 0
        case "center", "middle":
            return 0.5
        case "right":
            return 1
        default:
            guard let value = Double(raw),
                value.isFinite,
                (0...1).contains(value)
            else {
                throw CLIError(
                    message: String(
                        localized: "cli.dynamicNotch.error.invalidPosition",
                        defaultValue:
                            "Dynamic Notch position must be left, center, right, or a number from 0 to 1."
                    ),
                    exitCode: 2
                )
            }
            return value
        }
    }

    private func dynamicNotchPositionArguments(
        _ commandArgs: [String],
        client: SocketClient
    ) throws -> (position: Double, displayKey: String?) {
        guard commandArgs.count == 2 || commandArgs.count == 4 else {
            throw dynamicNotchUsageError()
        }
        let position = try dynamicNotchPosition(commandArgs[1])
        let displayKey = try dynamicNotchDisplayKey(
            from: Array(commandArgs.dropFirst(2)),
            client: client
        )
        return (position, displayKey)
    }

    private func dynamicNotchSizeArguments(
        _ commandArgs: [String],
        client: SocketClient
    ) throws -> (width: Double, height: Double, displayKey: String?) {
        guard commandArgs.count == 3 || commandArgs.count == 5,
            let width = Double(commandArgs[1]),
            let height = Double(commandArgs[2]),
            width.isFinite,
            height.isFinite,
            (300 ... 1_200).contains(width),
            (160 ... 1_400).contains(height)
        else {
            throw CLIError(
                message: String(
                    localized: "cli.dynamicNotch.error.invalidSize",
                    defaultValue:
                        "Dynamic Notch size must use a width from 300 to 1200 and height from 160 to 1400."
                ),
                exitCode: 2
            )
        }
        let displayKey = try dynamicNotchDisplayKey(
            from: Array(commandArgs.dropFirst(3)),
            client: client
        )
        return (width, height, displayKey)
    }

    private func dynamicNotchDisplayKey(
        from arguments: [String],
        client: SocketClient
    ) throws -> String? {
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 2,
            arguments[0] == "--display"
        else {
            throw dynamicNotchUsageError()
        }
        let selector = arguments[1]
        let status = try client.sendV2(
            method: "notification.dynamic_notch.settings"
        )
        let displays = status["displays"] as? [[String: Any]] ?? []
        let normalized = selector.lowercased()
        let matches = displays.filter { display in
            let key = display["key"] as? String ?? ""
            let name = display["name"] as? String ?? ""
            let id = (display["id"] as? NSNumber)?.stringValue ?? ""
            return key == selector
                || id == selector
                || name.lowercased() == normalized
        }
        guard matches.count == 1,
            let key = matches[0]["key"] as? String
        else {
            let available = displays.compactMap { display -> String? in
                guard let name = display["name"] as? String,
                    let key = display["key"] as? String
                else {
                    return nil
                }
                let id = (display["id"] as? NSNumber)?.stringValue ?? "?"
                return "\(name) (\(id), \(key))"
            }.joined(separator: ", ")
            throw CLIError(
                message: String.localizedStringWithFormat(
                    String(
                        localized:
                            "cli.dynamicNotch.error.displayNotFound",
                        defaultValue:
                            "Display '%@' did not match exactly one connected display. Available: %@"
                    ),
                    selector,
                    available
                ),
                exitCode: 2
            )
        }
        return key
    }

    private func printDynamicNotchDisplays(_ rawDisplays: Any?) {
        guard let displays = rawDisplays as? [[String: Any]],
            !displays.isEmpty
        else {
            return
        }
        print(
            String(
                localized: "cli.dynamicNotch.displays",
                defaultValue: "Displays:"
            )
        )
        let format = String(
            localized: "cli.dynamicNotch.display",
            defaultValue: "  %@ (%@): %.2f, %.0f × %.0f [%@]"
        )
        for display in displays {
            let key = display["key"] as? String ?? ""
            let name = display["name"] as? String ?? key
            let id = (display["id"] as? NSNumber)?.stringValue ?? "?"
            let position =
                (display["horizontal_position"] as? NSNumber)?
                .doubleValue ?? 0.5
            let width =
                (display["expanded_width"] as? NSNumber)?
                .doubleValue ?? 460
            let height =
                (display["expanded_height"] as? NSNumber)?
                .doubleValue ?? 520
            print(
                String.localizedStringWithFormat(
                    format,
                    name,
                    id,
                    position,
                    width,
                    height,
                    key
                )
            )
        }
    }

    private func printDynamicNotchSwipeActions(_ rawActions: Any?) {
        guard let actions = rawActions as? [String: [String: Any]],
            !actions.isEmpty else {
            return
        }
        print(
            String(
                localized: "cli.dynamicNotch.swipeActions",
                defaultValue: "Swipe actions:"
            )
        )
        let format = String(
            localized: "cli.dynamicNotch.swipeAction",
            defaultValue: "  %@: left=%@ right=%@"
        )
        for rowKind in ["notification", "feed", "unread"] {
            guard let directions = actions[rowKind] else { continue }
            print(
                String.localizedStringWithFormat(
                    format,
                    rowKind,
                    directions["left"] as? String ?? "none",
                    directions["right"] as? String ?? "none"
                )
            )
        }
    }

    private func dynamicNotchUsageError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.dynamicNotch.error.usage",
                defaultValue:
                    "Usage: cmux dynamic-notch <status|enable|disable|toggle|show|compact|hide|auto|position|center|reset-position|size|reset-size|swipe|reset-swipe> [arguments] [--display <id|name|key>] [--json]"
            ),
            exitCode: 2
        )
    }
}
