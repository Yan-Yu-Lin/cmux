import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        relevantPanelKeys: Set<RestorableAgentSessionIndex.PanelKey>? = nil
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                maximumSnapshotAge: 5,
                relevantPanelKeys: relevantPanelKeys
            )
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil,
        relevantPanelKeys: Set<RestorableAgentSessionIndex.PanelKey>? = nil
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let unfilteredProcessSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureDiscoveryCached(maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.captureDiscovery()
        }
        let processSnapshot = relevantPanelKeys.map {
            unfilteredProcessSnapshot.filteringProcessTrees(for: $0)
        } ?? unfilteredProcessSnapshot
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            relevantPanelKeys: relevantPanelKeys
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}
