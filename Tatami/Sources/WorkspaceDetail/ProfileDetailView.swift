import ComposableArchitecture
import SwiftUI
import TatamiKit

private enum CountMode: Hashable { case any, exactly, atLeast, atMost }
/// Per-monitor requirement in the auto-activation editor.
private enum DisplayReq: Hashable { case any, required, excluded }

/// Settings for the selected profile — name, switch shortcut, auto-activation
/// rule, activate + delete. Shown in the detail pane like a workspace's detail.
struct ProfileDetailView: View {
  @Bindable var store: StoreOf<ProfileDetailFeature>

  var body: some View {
    if let profile = store.profile {
      Form {
        Section {
          TextField("Name", text: Binding(
            get: { profile.name },
            set: { store.send(.nameChanged($0)) }
          ))
        }

        Section {
          ShortcutRecorder(
            hotKey: profile.shortcut,
            conflict: { store.state.shortcutConflict(for: $0) },
            onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
            onChange: { store.send(.shortcutChanged($0)) }
          )
        } header: {
          Text("Switch Shortcut")
        } footer: {
          Text("Press to switch to this profile from anywhere.")
            .font(.caption).foregroundStyle(.secondary)
        }

        autoActivationSection(profile)
      }
      .formStyle(.grouped)
      .navigationTitle(profile.name)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.activateTapped)
          } label: {
            Label(
              store.isActive ? "Active" : "Activate",
              systemImage: store.isActive ? "checkmark.circle.fill" : "play.fill"
            )
          }
          .disabled(store.isActive)
          .help(store.isActive ? "This profile is already active." : "Activate this profile.")
        }
      }
      .task { store.send(.onAppear) }
    } else {
      ContentUnavailableView(
        "Profile Unavailable",
        systemImage: "rectangle.stack",
        description: Text("This profile no longer exists.")
      )
    }
  }

  // MARK: - Auto-activation editor

  /// Persist the edited rule. While auto-activation is on, an all-Any rule is a
  /// deliberate catch-all (kept non-nil); the section's toggle owns `nil` (off).
  private func emit(_ rule: ProfileActivation) {
    store.send(.autoActivationChanged(rule))
  }

  @ViewBuilder
  private func autoActivationSection(_ profile: Profile) -> some View {
    let enabled = profile.autoActivation != nil
    let cur = profile.autoActivation ?? ProfileActivation()
    Section {
      Toggle("Auto-activate this profile", isOn: Binding(
        get: { enabled },
        // On → keep/seed a rule (empty = catch-all); off → nil (manual only).
        set: { on in store.send(.autoActivationChanged(on ? cur : nil)) }
      ))

      if enabled {
        if !cur.hasConditions {
          Label {
            Text("No conditions — activates on any configuration. Add a monitor condition below to narrow it.")
          } icon: {
            Image(systemName: "info.circle")
          }
          .font(.caption).foregroundStyle(.secondary)
        }

        Picker("Monitor count", selection: Binding<CountMode>(
          get: {
            switch cur.displayCount {
            case .none: .any
            case .exactly: .exactly
            case .atLeast: .atLeast
            case .atMost: .atMost
            }
          },
          set: { mode in
            let n = cur.displayCount.map(count) ?? max(1, store.availableDisplays.count)
            var next = cur
            switch mode {
            case .any: next.displayCount = nil
            case .exactly: next.displayCount = .exactly(n)
            case .atLeast: next.displayCount = .atLeast(n)
            case .atMost: next.displayCount = .atMost(n)
            }
            emit(next)
          }
        )) {
          Text("Any").tag(CountMode.any)
          Text("Exactly").tag(CountMode.exactly)
          Text("At least").tag(CountMode.atLeast)
          Text("At most").tag(CountMode.atMost)
        }
        if let dc = cur.displayCount {
          Stepper(
            "\(count(dc)) monitor\(count(dc) == 1 ? "" : "s")",
            value: Binding<Int>(
              get: { count(dc) },
              set: { n in
                var next = cur
                switch dc {
                case .exactly: next.displayCount = .exactly(n)
                case .atLeast: next.displayCount = .atLeast(n)
                case .atMost: next.displayCount = .atMost(n)
                }
                emit(next)
              }
            ),
            in: 1 ... 8
          )
        }

        // Per-monitor requirement: Required (must be connected) / Excluded
        // (must be unplugged) / Any. Clearer than separate lists.
        if store.availableDisplays.isEmpty {
          Text("No monitors detected yet.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(store.availableDisplays, id: \.self) { display in
            Picker(display.name, selection: Binding<DisplayReq>(
              get: {
                if cur.whenDisconnected.contains(where: { $0.matches(display) }) { return .excluded }
                if cur.whenConnected?.displays.contains(where: { $0.matches(display) }) ?? false { return .required }
                return .any
              },
              set: { req in
                var required = (cur.whenConnected?.displays ?? []).filter { !$0.matches(display) }
                var excluded = cur.whenDisconnected.filter { !$0.matches(display) }
                switch req {
                case .any: break
                case .required: required.append(display)
                case .excluded: excluded.append(display)
                }
                var next = cur
                next.whenConnected = required.isEmpty ? nil : .contains(required)
                next.whenDisconnected = excluded
                emit(next)
              }
            )) {
              Text("Any").tag(DisplayReq.any)
              Text("Required").tag(DisplayReq.required)
              Text("Excluded").tag(DisplayReq.excluded)
            }
          }
        }

        let diagnostic = store.autoActivationDiagnostic
        if !diagnostic.isEmpty { diagnosticRows(diagnostic) }
      }
    } header: {
      Text("Auto-Activation")
    } footer: {
      Text("When on, auto-switch to this profile as the monitors match — all conditions apply together. Per monitor: Required = must be connected, Excluded = must be unplugged.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func count(_ rule: CountRule) -> Int {
    switch rule { case .exactly(let n), .atLeast(let n), .atMost(let n): n }
  }

  // MARK: - Overlap diagnostic

  /// Inline warning (equal-specificity conflict) + info (intended shadowing)
  /// about how this profile's rule overlaps the others'.
  @ViewBuilder
  private func diagnosticRows(_ d: ProfileActivationDiagnostic) -> some View {
    if !d.ambiguousWith.isEmpty {
      Label {
        Text("Also matches \(quoted(d.ambiguousWith)) at the same priority — profile order decides which one activates. Make one more specific, or reorder them in the sidebar.")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      .font(.caption)
    }
    if !d.shadowedBy.isEmpty {
      Label {
        Text("Overlaps \(quoted(d.shadowedBy)) — more specific, so it wins where both match.")
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    if !d.shadows.isEmpty {
      Label {
        Text("Wins over \(quoted(d.shadows)) where both match.")
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func quoted(_ names: [String]) -> String {
    names.map { "“\($0)”" }.joined(separator: ", ")
  }
}
