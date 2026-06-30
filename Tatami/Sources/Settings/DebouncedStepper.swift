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

/// A `Slider` whose value lives in local `@State`, committed to the shared
/// config on a short debounce — same rationale as `DebouncedStepper`. Binding
/// a Slider directly to the observed `@Shared` config wrote the config (and
/// synchronously re-rendered the whole `SettingsView` Form) on every drag
/// tick. The live readout reads the local value so the number tracks the
/// thumb without touching the store until the drag settles.
struct DebouncedSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
  let title: String
  let external: V
  let range: ClosedRange<V>
  let step: V.Stride
  let minLabel: String
  let maxLabel: String
  let detail: String?
  let readout: (V) -> String
  let commit: (V) -> Void
  @State private var local: V

  init(
    title: String,
    external: V,
    range: ClosedRange<V>,
    step: V.Stride,
    minLabel: String,
    maxLabel: String,
    detail: String? = nil,
    readout: @escaping (V) -> String,
    commit: @escaping (V) -> Void
  ) {
    self.title = title
    self.external = external
    self.range = range
    self.step = step
    self.minLabel = minLabel
    self.maxLabel = maxLabel
    self.detail = detail
    self.readout = readout
    self.commit = commit
    _local = State(initialValue: external)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(readout(local))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: $local, in: range, step: step) {
        Text(title)
      } minimumValueLabel: {
        Text(minLabel)
      } maximumValueLabel: {
        Text(maxLabel)
      }
      .labelsHidden()
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    // Persist after the drag settles. `.task(id:)` cancels the prior run
    // whenever `local` changes, so rapid ticks coalesce into one write.
    .task(id: local) {
      guard local != external else { return }
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      commit(local)
    }
    .onChange(of: external) { _, newValue in
      if newValue != local { local = newValue }
    }
  }
}
