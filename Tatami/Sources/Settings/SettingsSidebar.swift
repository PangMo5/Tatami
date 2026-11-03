// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

/// Search text belongs to the sidebar so typing does not rebuild the form.
struct SettingsSidebar: View {

  // MARK: Internal

  typealias Pane = SettingsView.Pane

  let config: AppConfig
  @Binding var pane: Pane?

  let focusRequest: UInt64
  let resetRequest: UInt64
  let onSelect: (SettingsSearchItem) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search Settings", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .accessibilityIdentifier("settings-search")
          .onExitCommand { searchText = "" }
        if !searchText.isEmpty {
          Button("Clear Search", systemImage: "xmark.circle.fill") {
            searchText = ""
            isSearchFocused = true
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .background(.quaternary, in: .rect(cornerRadius: 8))
      .padding(10)

      if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        List(selection: $pane) {
          ForEach(Pane.allCases.filter { $0 != .hooks }, id: \.self) { pane in
            Label(pane.title, systemImage: pane.icon).tag(pane)
          }
          Section("Advanced") {
            Label(Pane.hooks.title, systemImage: Pane.hooks.icon).tag(Pane.hooks)
          }
        }
        .listStyle(.sidebar)
      } else {
        let results = SettingsSearch.results(for: searchText, in: SettingsSearchCatalog.items(config: config))
        List {
          if results.isEmpty {
            Text("No settings found")
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("settings-search-empty")
          }
          ForEach(results) { item in
            Button {
              onSelect(item)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2)
                if let destination = Pane(rawValue: item.pane) {
                  Text(destination.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-result-\(item.id)")
          }
        }
        .listStyle(.sidebar)
      }
    }
    .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
    .onChange(of: focusRequest) { isSearchFocused = true }
    .onChange(of: resetRequest) { searchText = "" }
  }

  // MARK: Private

  @State private var searchText = ""
  @FocusState private var isSearchFocused: Bool

}
