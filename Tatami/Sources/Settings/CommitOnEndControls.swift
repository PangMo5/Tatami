import SwiftUI

// MARK: - CommitOnChangeStepper

/// A `Stepper` whose value lives in local `@State`, committed to the shared
/// config after its value changes. Binding a `Stepper` directly to the observed
/// `@Shared` config made a single click run away: each step wrote the config,
/// which synchronously re-rendered the whole `SettingsView` (its label also
/// reads the config), and that re-render churned the Stepper's press tracking
/// so it auto-repeated to the range bound. Stepping local `@State` keeps the
/// press loop free of the observed store; the value-keyed task commits on the
/// next SwiftUI update cycle without depending on a gesture-ended callback.
struct CommitOnChangeStepper<V: Strideable>: View {

  // MARK: Lifecycle

  init(
    external: V,
    range: ClosedRange<V>,
    step: V.Stride = 1,
    detail: LocalizedStringResource? = nil,
    label: @escaping (V) -> LocalizedStringResource,
    commit: @escaping (V) -> Void,
  ) {
    self.external = external
    self.range = range
    self.step = step
    self.detail = detail
    self.label = label
    self.commit = commit
    _local = State(initialValue: external)
  }

  // MARK: Internal

  let external: V
  let range: ClosedRange<V>
  let step: V.Stride
  let detail: LocalizedStringResource?
  let label: (V) -> LocalizedStringResource
  let commit: (V) -> Void

  var body: some View {
    Stepper(value: $local, in: range, step: step) {
      Text(label(local))
      if let detail { Text(detail) }
    }
    .task(id: local) {
      guard local != external else { return }
      await Task.yield()
      guard !Task.isCancelled, local != external else { return }
      commit(local)
    }
    // Reflect external changes (config edited elsewhere) back into the value.
    .onChange(of: external) { _, newValue in
      if newValue != local { local = newValue }
    }
  }

  // MARK: Private

  @State private var local: V

}

// MARK: - CommitOnEndSlider

/// A `Slider` whose value lives in local `@State`, committed to the shared
/// config when interaction ends. Binding
/// a Slider directly to the observed `@Shared` config wrote the config (and
/// synchronously re-rendered the whole `SettingsView` Form) on every drag
/// tick. The live readout tracks the thumb without touching the store; the
/// control's editing-ended event commits immediately, with no timer.
struct CommitOnEndSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {

  // MARK: Lifecycle

  init(
    title: LocalizedStringResource,
    external: V,
    range: ClosedRange<V>,
    step: V.Stride,
    minLabel: LocalizedStringResource,
    maxLabel: LocalizedStringResource,
    detail: LocalizedStringResource? = nil,
    readout: @escaping (V) -> String,
    commit: @escaping (V) -> Void,
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

  // MARK: Internal

  let title: LocalizedStringResource
  let external: V
  let range: ClosedRange<V>
  let step: V.Stride
  let minLabel: LocalizedStringResource
  let maxLabel: LocalizedStringResource
  let detail: LocalizedStringResource?
  let readout: (V) -> String
  let commit: (V) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(readout(local))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: $local,
        in: range,
        step: step,
      ) {
        Text(title)
      } minimumValueLabel: {
        Text(minLabel)
      } maximumValueLabel: {
        Text(maxLabel)
      } onEditingChanged: { isEditing in
        if !isEditing, local != external {
          commit(local)
        }
      }
      .labelsHidden()
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onChange(of: external) { _, newValue in
      if newValue != local { local = newValue }
    }
  }

  // MARK: Private

  @State private var local: V

}
