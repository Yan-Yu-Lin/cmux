import SwiftUI

/// Search, time-range, grouping, sorting, and reload controls for History.
struct VaultHistoryControls: View {
    @Bindable var model: VaultHistoryTimelineModel
    let isReloadDisabled: Bool
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                timeRangeMenu
                groupMenu
                Spacer(minLength: 4)
                sortMenu
                reloadButton
            }
            .rightSidebarChromeBar()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "vaultHistory.search.placeholder", defaultValue: "Search history"),
                    text: $model.searchText
                )
                .textFieldStyle(.plain)
                .cmuxFont(size: 11)
                .accessibilityIdentifier("VaultHistorySearchField")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(
                        localized: "vaultHistory.search.clear.tooltip",
                        defaultValue: "Clear history search"
                    ))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: RightSidebarChromeMetrics.secondaryBarHeight)
        }
        .rightSidebarChromeBottomBorder()
    }

    private var timeRangeMenu: some View {
        Menu {
            ForEach(VaultHistoryQuery.TimeRange.allCases) { range in
                Button {
                    model.timeRange = range
                } label: {
                    if model.timeRange == range {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
        } label: {
            Label(model.timeRange.label, systemImage: model.timeRange.symbolName)
                .cmuxFont(
                    size: RightSidebarChromeControlStyle.labelSize,
                    weight: RightSidebarChromeControlStyle.labelWeight
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "vaultHistory.rangePicker.tooltip", defaultValue: "Filter history by time"))
        .accessibilityIdentifier("VaultHistoryTimeRangePicker")
        .titlebarInteractiveControl()
    }

    private var groupMenu: some View {
        Menu {
            ForEach(VaultHistoryGroupKey.allCases) { key in
                Button {
                    model.groupKey = key
                } label: {
                    if model.groupKey == key {
                        Label(key.label, systemImage: "checkmark")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Image(systemName: model.groupKey.symbolName)
                .cmuxFont(
                    size: RightSidebarChromeControlStyle.secondaryIconSize,
                    weight: RightSidebarChromeControlStyle.iconWeight
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "vaultHistory.groupPicker.tooltip", defaultValue: "Group history by"))
        .accessibilityIdentifier("VaultHistoryGroupPicker")
        .titlebarInteractiveControl()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(VaultHistoryQuery.SortOrder.allCases) { order in
                Button {
                    model.sortOrder = order
                } label: {
                    if model.sortOrder == order {
                        Label(order.label, systemImage: "checkmark")
                    } else {
                        Text(order.label)
                    }
                }
            }
        } label: {
            Image(systemName: model.sortOrder.symbolName)
                .cmuxFont(
                    size: RightSidebarChromeControlStyle.secondaryIconSize,
                    weight: RightSidebarChromeControlStyle.iconWeight
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "vaultHistory.sortPicker.tooltip", defaultValue: "Sort history"))
        .accessibilityIdentifier("VaultHistorySortPicker")
        .titlebarInteractiveControl()
    }

    private var reloadButton: some View {
        Button {
            onReload()
        } label: {
            Image(systemName: "arrow.clockwise")
                .cmuxFont(size: 10, weight: .medium)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "vaultHistory.reload.tooltip", defaultValue: "Reload History"))
        .disabled(isReloadDisabled)
        .titlebarInteractiveControl()
    }
}
