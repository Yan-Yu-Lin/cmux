import CMUXAgentLaunch
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dynamic Notch notification tray")
struct DynamicNotchNotificationTrayModelTests {
    @Test("Notifications accumulate newest first and resolve independently")
    func notificationsAccumulateAndResolveIndependently() {
        let model = DynamicNotchNotificationTrayModel()
        let first = makeNotification(title: "First")
        let second = makeNotification(title: "Second")

        #expect(model.enqueue(first))
        #expect(model.enqueue(second))
        #expect(model.notifications.map(\.id) == [second.id, first.id])

        model.transition(to: .expanded)
        #expect(model.phase == .expanded)
        #expect(model.remove(id: second.id) == second)
        #expect(model.notifications == [first])
        #expect(model.phase == .expanded)

        #expect(model.remove(id: first.id) == first)
        #expect(model.notifications.isEmpty)
        #expect(model.phase == .retracted)
    }

    @Test("Duplicate notification identifiers do not create duplicate rows")
    func duplicateIdentifiersAreIgnored() {
        let model = DynamicNotchNotificationTrayModel()
        let notification = makeNotification(title: "Approval")

        #expect(model.enqueue(notification))
        #expect(!model.enqueue(notification))
        #expect(model.notifications == [notification])
    }

    @Test("Same-identifier upsert refreshes without replacing another row")
    func sameIdentifierUpsertRefreshesOneRow() {
        let model = DynamicNotchNotificationTrayModel()
        let first = makeNotification(title: "Step 1")
        let replacement = makeNotification(id: first.id, title: "Step 2")
        #expect(model.enqueue(first))
        model.transition(to: .expanded)

        let removed = model.upsert(replacement)

        #expect(removed == first)
        #expect(model.notifications == [replacement])
        #expect(model.phase == .expanded)
    }

    @Test("Newest notification controls the tray while rows retain their overrides")
    func appearancePrecedenceFollowsNewestNotification() throws {
        let global = DynamicNotchAppearance()
            .replacing(.number(520), for: .expandedWidth)
            .replacing(.color(.hex("#112233")), for: .primaryTextColor)
        let model = DynamicNotchNotificationTrayModel(globalAppearance: global)
        let first = makeNotification(
            title: "First",
            appearance: try DynamicNotchAppearanceOverrides(assignments: [
                "expandedWidth=600",
                "accentColor=#FF0000",
            ])
        )
        let second = makeNotification(
            title: "Second",
            appearance: try DynamicNotchAppearanceOverrides(assignments: [
                "expandedWidth=700",
                "bodyLineLimit=8",
            ])
        )

        #expect(model.enqueue(first))
        #expect(model.enqueue(second))
        #expect(model.trayAppearance[.expandedWidth] == .number(700))
        #expect(model.appearance(for: first)[.expandedWidth] == .number(600))
        #expect(model.appearance(for: first)[.primaryTextColor] == .color(.hex("#112233")))
        #expect(model.appearance(for: second)[.bodyLineLimit] == .integer(8))

        _ = model.remove(id: second.id)
        #expect(model.trayAppearance[.expandedWidth] == .number(600))
    }

    @Test("Global appearance changes re-resolve inherited row values")
    func globalAppearanceUpdatesRows() {
        let model = DynamicNotchNotificationTrayModel()
        let notification = makeNotification(title: "Inherited")
        #expect(model.enqueue(notification))

        model.setGlobalAppearance(
            DynamicNotchAppearance().replacing(
                .number(720),
                for: .expandedWidth
            )
        )

        #expect(model.trayAppearance[.expandedWidth] == .number(720))
        #expect(model.appearance(for: notification)[.expandedWidth] == .number(720))
    }

    @Test("Display position stays local and wins over row overrides")
    func displayPositionOverridesNotificationPosition() throws {
        let model = DynamicNotchNotificationTrayModel(
            displayHorizontalPosition: 0.2
        )
        let notification = makeNotification(
            title: "Positioned",
            appearance: try DynamicNotchAppearanceOverrides(assignments: [
                "syntheticNotchHorizontalPosition=0.9",
            ])
        )
        #expect(model.enqueue(notification))

        #expect(
            model.trayAppearance[.syntheticNotchHorizontalPosition]
                == .number(0.2)
        )

        model.setDisplayHorizontalPosition(0.7)
        #expect(
            model.trayAppearance[.syntheticNotchHorizontalPosition]
                == .number(0.7)
        )
    }

    @Test("Persistent island remains available without notification rows")
    func persistentIslandRemainsAvailable() {
        let model = DynamicNotchNotificationTrayModel(
            keepsDefaultIslandVisible: true
        )

        #expect(model.isAvailable)
        model.transition(to: .compact)
        #expect(model.phase == .compact)

        model.setKeepsDefaultIslandVisible(false)
        #expect(!model.isAvailable)
        #expect(model.phase == .retracted)
    }

    @Test("Feed snapshot keeps bounded source rows newest first with stable IDs")
    func feedSnapshotUsesStableSourceIdentities() {
        let model = DynamicNotchNotificationTrayModel()
        let items = (0..<WorkstreamDefaultRingCapacity).map { index in
            makeFeedItem(index: index)
        }

        model.setFeedItems(items)

        #expect(model.feedItems.count == WorkstreamDefaultRingCapacity)
        #expect(model.feedItems.first?.id == items.last?.id)
        #expect(model.feedItems.last?.id == items.first?.id)
        #expect(Set(model.feedItems.map(\.id)).count == model.feedItems.count)

        let hiddenID = items[500].id
        model.hideFeedItem(id: hiddenID)
        model.setFeedItems(items)
        #expect(!model.feedItems.contains(where: { $0.id == hiddenID }))
    }

    @Test("Unread badge deduplicates runtime notifications by stable ID")
    func unreadBadgeDeduplicatesRuntimeRows() {
        let model = DynamicNotchNotificationTrayModel(
            keepsDefaultIslandVisible: true
        )
        let shared = makeNotification(title: "Shared")
        let unreadOnly = makeNotification(title: "Unread only")

        #expect(model.enqueue(shared))
        model.setUnreadNotifications([shared, unreadOnly])

        #expect(model.feedCount == 1)
        #expect(model.unreadCount == 2)
        #expect(model.badgeCount == 2)
    }

    @Test("Per-display size and swipe settings resolve independently")
    func displaySizeAndSwipeSettingsResolve() {
        let size = DynamicNotchDisplaySize(width: 720, height: 640)
        var swipes = DynamicNotchSwipeActions()
        swipes = swipes.setting(
            .hide,
            for: .notification,
            direction: .right
        )
        let model = DynamicNotchNotificationTrayModel(
            displayExpandedSize: size,
            maximumExpandedSize: DynamicNotchDisplaySize(
                width: 680,
                height: 600
            ),
            swipeActions: swipes
        )

        #expect(model.resolvedExpandedWidth == 680)
        #expect(model.resolvedExpandedHeight == 600)
        #expect(
            model.swipeActions.action(
                for: .notification,
                direction: .right
            ) == .hide
        )
    }

    private func makeNotification(
        id: UUID = UUID(),
        title: String,
        appearance: DynamicNotchAppearanceOverrides = DynamicNotchAppearanceOverrides()
    ) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: UUID(),
            surfaceId: UUID(),
            title: title,
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false,
            presentation: TerminalNotificationPresentation(
                appearance: appearance
            )
        )
    }

    private func makeFeedItem(index: Int) -> WorkstreamItem {
        WorkstreamItem(
            id: UUID(),
            workstreamId: "workstream-\(index)",
            source: .codex,
            kind: .permissionRequest,
            createdAt: Date(timeIntervalSince1970: Double(index)),
            payload: .permissionRequest(
                requestId: "request-\(index)",
                toolName: "shell",
                toolInputJSON: "{}",
                pattern: nil
            )
        )
    }
}

@Suite("Dynamic Notch appearance settings file", .serialized)
struct DynamicNotchAppearanceSettingsFileTests {
    private let backupsKey = "cmux.settingsFile.backups.v1"
    private let importedKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test("cmux.json applies validated appearance and advertises every leaf path")
    func settingsFileAppliesAppearance() throws {
        let setting = SettingCatalog().notifications.dynamicNotch
        let positionsSetting = SettingCatalog().notifications
            .dynamicNotchDisplayPositions
        let sizesSetting = SettingCatalog().notifications
            .dynamicNotchDisplaySizes
        let swipesSetting = SettingCatalog().notifications
            .dynamicNotchSwipeActions
        let defaults = UserDefaults.standard
        let keys = [
            setting.userDefaultsKey,
            positionsSetting.userDefaultsKey,
            sizesSetting.userDefaultsKey,
            swipesSetting.userDefaultsKey,
            backupsKey,
            importedKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-dynamic-notch-appearance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "dynamicNotch": {
              "expandedWidth": 680,
              "accentColor": "#AABBCC",
              "showScrollIndicators": false
            },
            "dynamicNotchDisplayPositions": {
              "uuid:external": 0.25
            },
            "dynamicNotchDisplaySizes": {
              "uuid:external": {
                "width": 720,
                "height": 640
              }
            },
            "dynamicNotchSwipeActions": {
              "notification": {
                "left": "dismiss",
                "right": "hide"
              },
              "feed": {
                "left": "hide",
                "right": "open"
              },
              "unread": {
                "left": "markRead",
                "right": "open"
              }
            }
          }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        let appearance = UserDefaultsSettingsClient(defaults: defaults).value(
            for: setting
        )
        #expect(appearance[.expandedWidth] == .number(680))
        #expect(appearance[.accentColor] == .color(.hex("#AABBCC")))
        #expect(appearance[.showScrollIndicators] == .boolean(false))
        #expect(
            UserDefaultsSettingsClient(defaults: defaults).value(
                for: positionsSetting
            ) == ["uuid:external": "0.25"]
        )
        #expect(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                "notifications.dynamicNotch"
            )
        )
        for token in DynamicNotchAppearanceToken.allCases {
            #expect(
                CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                    "notifications.dynamicNotch.\(token.rawValue)"
                )
            )
        }
        #expect(
            CmuxSettingsFileStore.defaultTemplate().contains(
                #""dynamicNotch""#
            )
        )
        #expect(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                "notifications.dynamicNotchDisplayPositions"
            )
        )
        #expect(
            UserDefaultsSettingsClient(defaults: defaults).value(
                for: sizesSetting
            ) == ["uuid:external": "720.0,640.0"]
        )
        #expect(
            UserDefaultsSettingsClient(defaults: defaults).value(
                for: swipesSetting
            ).action(for: .notification, direction: .right) == .hide
        )
        #expect(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                "notifications.dynamicNotchDisplaySizes"
            )
        )
        #expect(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                "notifications.dynamicNotchSwipeActions"
            )
        )
        #expect(
            CmuxSettingsFileStore.defaultTemplate().contains(
                #""dynamicNotchSwipeActions""#
            )
        )
    }
}
