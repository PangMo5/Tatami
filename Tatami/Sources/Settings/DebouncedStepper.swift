import SwiftUI

/// A `Stepper` whose value lives in local `@State`, committed to the shared
/// config on a short debounce. Binding a `Stepper` directly to the observed
/// `@Shared` config made a single click run away: each step wrote the config,
/// which synchronously re-rendered the whole `SettingsView` (its label also
/// reads the config), and that re-render churned the Stepper's press tracking
/// so it auto-repeated to the range bound. Stepping local `@State` keeps the
/// press loop free of the observed store; the debounced `commit` persists once
/// the user stops.
struct DebouncedStepper<V: Strideable>: View {
  let external: V
  let range: ClosedRange<V>
  let step: V.Stride
  let detail: String?
  let label: (V) -> String
  let commit: (V) -> Void
  @State private var local: V

  init(
    external: V,
    range: ClosedRange<V>,
    step: V.Stride = 1,
    detail: String? = nil,
    label: @escaping (V) -> String,
    commit: @escaping (V) -> Void
  ) {
    self.external = external
    self.range = range
    self.step = step
    self.detail = detail
    self.label = label
    self.commit = commit
    _local = State(initialValue: external)
  }

  var body: some View {
    Stepper(value: $local, in: range, step: step) {
      Text(label(local))
      if let detail { Text(detail) }
    }
    // Persist after the user stops stepping. `.task(id:)` cancels the prior
    // run whenever `local` changes, so rapid steps coalesce into one write.
    .task(id: local) {
      guard local != external else { return }
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      commit(local)
    }
    // Reflect external changes (config edited elsewhere) back into the value.
    .onChange(of: external) { _, newValue in
      if newValue != local { local = newValue }
    }
  }
}
