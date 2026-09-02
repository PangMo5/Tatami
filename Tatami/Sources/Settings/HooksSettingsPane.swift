// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit
import UniformTypeIdentifiers

// MARK: - HooksSettingsPane

struct HooksSettingsPane: View {
  @Bindable var store: StoreOf<HookSettingsFeature>

  var body: some View {
    HooksIntroductionSection(
      isDisabled: store.mutationInFlight != nil,
      showsAddButton: !store.rows.isEmpty,
      addHook: { store.send(.addButtonTapped) },
    )

    HooksListSection(
      rows: store.rows,
      mutationInFlight: store.mutationInFlight,
      addHook: { store.send(.addButtonTapped) },
      editHook: { store.send(.editButtonTapped($0)) },
      deleteHook: { store.send(.deleteButtonTapped($0)) },
      setEnabled: { store.send(.enabledChanged($0, $1)) },
    )
    .task { await store.send(.task).finish() }
    .sheet(item: $store.scope(state: \.editor, action: \.editor)) { editorStore in
      HookEditorView(store: editorStore)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

// MARK: - HooksIntroductionSection

private struct HooksIntroductionSection: View {
  let isDisabled: Bool
  let showsAddButton: Bool
  let addHook: () -> Void

  var body: some View {
    Section {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Run a program when Tatami launches, changes profile, activates a workspace, or presents action feedback.")
          Text("Commands run directly with the arguments and environment shown below. A shell is never added automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        if showsAddButton {
          Button(action: addHook) {
            Label("Add Hook", systemImage: "plus")
          }
          .disabled(isDisabled)
        }
      }
    } header: {
      Text("Event Hooks")
    }
  }
}

// MARK: - HooksListSection

private struct HooksListSection: View {
  let rows: [HookSettingsFeature.Row]
  let mutationInFlight: HookSettingsFeature.Mutation?
  let addHook: () -> Void
  let editHook: (HookLocator) -> Void
  let deleteHook: (HookLocator) -> Void
  let setEnabled: (HookLocator, Bool) -> Void

  var body: some View {
    Section {
      if rows.isEmpty {
        ContentUnavailableView {
          Label("No Hooks", systemImage: "bolt.slash")
        } description: {
          Text("Add a hook to automate work outside Tatami.")
        } actions: {
          Button("Add Hook", action: addHook)
            .disabled(mutationInFlight != nil)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        ForEach(rows) { row in
          HookSummaryRow(
            row: row,
            isDisabled: mutationInFlight != nil,
            editHook: { editHook(row.locator) },
            deleteHook: { deleteHook(row.locator) },
            setEnabled: { setEnabled(row.locator, $0) },
          )
        }
      }
    } header: {
      Text("Configured Hooks")
    } footer: {
      Text("Hooks receive a JSON event on standard input. Disabled or invalid hooks do not run.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - HookSummaryRow

private struct HookSummaryRow: View {

  // MARK: Internal

  let row: HookSettingsFeature.Row
  let isDisabled: Bool
  let editHook: () -> Void
  let deleteHook: () -> Void
  let setEnabled: (Bool) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: row.definition.event.symbolName)
        .foregroundStyle(row.isValid ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(row.definition.id.isEmpty ? String(localized: "Unnamed Hook") : row.definition.id)
            .fontWeight(.medium)
          Text(row.definition.event.localizedTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
          Text(executableDescription)
            .lineLimit(1)
            .truncationMode(.middle)
          let argumentCount = max(0, row.definition.command.count - 1)
          if argumentCount > 0 {
            Group {
              if argumentCount == 1 {
                Text("· 1 argument")
              } else {
                Text("· \(argumentCount) arguments")
              }
            }
            .foregroundStyle(.secondary)
          }
        }
        .font(.caption.monospaced())
        if !row.isValid {
          Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      Spacer(minLength: 8)

      Toggle("Enabled", isOn: Binding(
        get: { row.definition.enabled },
        set: { enabled in setEnabled(enabled) },
      ))
      .labelsHidden()
      .disabled(isDisabled)
      .help(row.definition.enabled ? "Disable this hook" : "Enable this hook")

      Button("Edit", action: editHook)
        .disabled(isDisabled)

      Menu {
        Button("Delete", role: .destructive, action: deleteHook)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(isDisabled)
      .accessibilityLabel("More actions for \(row.definition.id)")
    }
    .padding(.vertical, 3)
  }

  // MARK: Private

  private var executableDescription: String {
    guard let executable = row.definition.command.first, !executable.isEmpty else {
      return String(localized: "Executable not set")
    }
    return executable
  }

}

// MARK: - HookEditorView

private struct HookEditorView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<HookEditorFeature>

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          HookGeneralEditorSection(store: store)
          HookProgramEditorSection(
            store: store,
            chooseExecutable: { isChoosingExecutable = true },
          )
          HookExecutionEditorSection(
            store: store,
            chooseWorkingDirectory: { isChoosingWorkingDirectory = true },
          )
          HookEnvironmentEditorSection(store: store)
          HookTestSection(store: store)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        HookEditorBottomBar(
          saveError: store.saveError,
          validationIssues: visibleValidationIssues,
          cancel: { store.send(.cancelButtonTapped) },
          save: { store.send(.saveButtonTapped) },
        )
      }
      .navigationTitle(store.mode.navigationTitle)
    }
    .frame(minWidth: 660, idealWidth: 720, minHeight: 620, idealHeight: 720)
    .fileImporter(
      isPresented: $isChoosingExecutable,
      allowedContentTypes: [.unixExecutable],
      allowsMultipleSelection: false,
    ) { result in
      guard let url = try? result.get().first else { return }
      store.send(.executableChanged(url.path(percentEncoded: false)))
    }
    .fileImporter(
      isPresented: $isChoosingWorkingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false,
    ) { result in
      guard let url = try? result.get().first else { return }
      store.send(.workingDirectoryChanged(url.path(percentEncoded: false)))
    }
  }

  // MARK: Private

  @State private var isChoosingExecutable = false
  @State private var isChoosingWorkingDirectory = false

  private var visibleValidationIssues: [HookEditorFeature.ValidationIssue] {
    guard store.showsValidation || store.showsTestValidation else { return [] }
    return store.showsTestValidation
      ? store.testValidationIssues
      : store.validationIssues
  }

}

// MARK: - HookEditorBottomBar

private struct HookEditorBottomBar: View {

  let saveError: String?
  let validationIssues: [HookEditorFeature.ValidationIssue]
  let cancel: () -> Void
  let save: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      HookEditorBottomBarStatus(
        saveError: saveError,
        validationIssues: validationIssues,
      )
      .layoutPriority(1)

      Spacer(minLength: 0)

      HStack(spacing: 8) {
        Button("Cancel", role: .cancel, action: cancel)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)

        Button("Save", action: save)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .fixedSize()
    }
    .controlSize(.regular)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
  }

}

// MARK: - HookEditorBottomBarStatus

private struct HookEditorBottomBarStatus: View {

  // MARK: Internal

  let saveError: String?
  let validationIssues: [HookEditorFeature.ValidationIssue]

  var body: some View {
    if saveError != nil || !validationIssues.isEmpty {
      Button {
        isShowingDetails.toggle()
      } label: {
        Label {
          Text(summary)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .lineLimit(1)
      }
      .buttonStyle(.plain)
      .foregroundStyle(saveError == nil ? Color.orange : Color.red)
      .help("Show error details")
      .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
        details
      }
    }
  }

  // MARK: Private

  @State private var isShowingDetails = false

  private var summary: LocalizedStringResource {
    if saveError != nil { return "Hook could not be saved" }
    if validationIssues.count == 1, let issue = validationIssues.first {
      return issue.code.localizedMessage
    }
    return "Check These Fields"
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(detailsTitle)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.headline)
      .foregroundStyle(saveError == nil ? Color.orange : Color.red)

      Divider()

      if let saveError {
        Text(saveError)
          .textSelection(.enabled)
      } else {
        ForEach(validationIssues, id: \.self) { issue in
          Text(issue.code.localizedMessage)
        }
      }
    }
    .frame(width: 340, alignment: .leading)
    .padding()
  }

  private var detailsTitle: LocalizedStringResource {
    saveError == nil ? "Check These Fields" : "Save Error"
  }

}

// MARK: - HookGeneralEditorSection

private struct HookGeneralEditorSection: View {
  let store: StoreOf<HookEditorFeature>

  var body: some View {
    Section {
      LabeledContent("Identifier") {
        TextField(
          "Hook identifier",
          text: Binding(
            get: { store.draft.id },
            set: { store.send(.idChanged($0)) },
          ),
          prompt: Text(verbatim: "notify-team"),
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 360)
        .accessibilityLabel("Hook identifier")
      }

      Picker("Event", selection: Binding(
        get: { store.draft.event },
        set: { store.send(.eventChanged($0)) },
      )) {
        ForEach(HookEvent.allCases, id: \.self) { event in
          Text(event.localizedTitle).tag(event)
        }
      }
      .pickerStyle(.menu)

      HookEventDataSummary(event: store.draft.event)

      Toggle("Enabled", isOn: Binding(
        get: { store.draft.enabled },
        set: { store.send(.enabledChanged($0)) },
      ))
    } header: {
      Text("Hook")
    } footer: {
      Text("Choose a unique name for this hook, such as notify-team. Tatami also sends it as TATAMI_HOOK_ID.")
    }
  }
}

// MARK: - HookEventDataSummary

private struct HookEventDataSummary: View {

  // MARK: Internal

  let event: HookEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(event.localizedPayloadDescription)
      } icon: {
        Image(systemName: "info.circle")
          .foregroundStyle(.tint)
      }

      dataRow("JSON Standard Input", value: event.jsonFields)
      dataRow("Tatami Environment Variables", value: event.environmentVariables)

      if event.hasOptionalPayload {
        Text("A question mark means the value is included only when available.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .font(.caption)
    .padding(.vertical, 4)
  }

  // MARK: Private

  private func dataRow(_ title: LocalizedStringResource, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      Text(verbatim: value)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

}

// MARK: - HookProgramEditorSection

private struct HookProgramEditorSection: View {
  let store: StoreOf<HookEditorFeature>
  let chooseExecutable: () -> Void

  var body: some View {
    Section {
      LabeledContent("Executable") {
        HStack(spacing: 8) {
          TextField(
            "Executable",
            text: Binding(
              get: { store.draft.executable },
              set: { store.send(.executableChanged($0)) },
            ),
            prompt: Text(verbatim: "/usr/local/bin/my-hook"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          Button("Choose...", action: chooseExecutable)
        }
        .frame(maxWidth: 480)
      }

      ForEach(store.draft.arguments) { argument in
        HStack(spacing: 8) {
          TextField(
            "Argument",
            text: Binding(
              get: {
                store.draft.arguments.first(where: { $0.id == argument.id })?.value
                  ?? argument.value
              },
              set: { store.send(.argumentValueChanged(argument.id, $0)) },
            ),
            prompt: Text("Argument"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())

          Button(role: .destructive) {
            store.send(.argumentDeleteButtonTapped(argument.id))
          } label: {
            Image(systemName: "minus.circle.fill")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove argument")
        }
      }

      Button {
        store.send(.argumentAddButtonTapped)
      } label: {
        Label("Add Argument", systemImage: "plus")
      }
    } header: {
      Text("Program")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(
          """
          Enter the path to a program, an executable script, or a command-line shell such as `/bin/zsh` or \
          `/opt/homebrew/bin/fish`. Shell locations vary, so use the full path returned by `which fish`. For a \
          script without execute permission, choose its command-line shell and add the script path as the first \
          argument.
          """
        )
        Text(
          """
          Each argument is passed exactly as one argv value. To use shell syntax, choose a command-line shell and \
          add its flags explicitly. For fish, use `/opt/homebrew/bin/fish` and add `-c` and `command ls` as separate \
          arguments. To open a macOS app, use `/usr/bin/open` as the executable and add `-a` and the app name as \
          separate arguments.
          """
        )
      }
    }
  }
}

// MARK: - HookExecutionEditorSection

private struct HookExecutionEditorSection: View {
  let store: StoreOf<HookEditorFeature>
  let chooseWorkingDirectory: () -> Void

  var body: some View {
    Section {
      LabeledContent("Working Directory") {
        HStack(spacing: 8) {
          TextField(
            "Working Directory",
            text: Binding(
              get: { store.draft.workingDirectory },
              set: { store.send(.workingDirectoryChanged($0)) },
            ),
            prompt: Text("Tatami configuration directory (default)"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          Button("Choose...", action: chooseWorkingDirectory)
        }
        .frame(maxWidth: 480)
      }

      LabeledContent("Timeout") {
        HStack(spacing: 6) {
          TextField(
            "Timeout",
            value: Binding(
              get: { store.draft.timeoutMs },
              set: { store.send(.timeoutChanged($0)) },
            ),
            format: .number,
            prompt: Text(verbatim: "5000"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
          Text("ms")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Execution")
    } footer: {
      Text(
        """
        Working Directory is the hook process's current directory. Relative paths used by the program are resolved \
        from it. Leave it empty to use Tatami's configuration directory. Timeout stops the process after the \
        specified number of milliseconds.
        """
      )
    }
  }
}

// MARK: - HookEnvironmentEditorSection

private struct HookEnvironmentEditorSection: View {
  let store: StoreOf<HookEditorFeature>

  var body: some View {
    Section {
      ForEach(store.draft.environment) { variable in
        HStack(spacing: 8) {
          TextField(
            "Name",
            text: Binding(
              get: {
                store.draft.environment.first(where: { $0.id == variable.id })?.key
                  ?? variable.key
              },
              set: { store.send(.environmentKeyChanged(variable.id, $0)) },
            ),
            prompt: Text("Name"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 180)
          .font(.body.monospaced())

          TextField(
            "Value",
            text: Binding(
              get: {
                store.draft.environment.first(where: { $0.id == variable.id })?.value
                  ?? variable.value
              },
              set: { store.send(.environmentValueChanged(variable.id, $0)) },
            ),
            prompt: Text("Value"),
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())

          Button(role: .destructive) {
            store.send(.environmentDeleteButtonTapped(variable.id))
          } label: {
            Image(systemName: "minus.circle.fill")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove environment variable")
        }
      }

      Button {
        store.send(.environmentAddButtonTapped)
      } label: {
        Label("Add Environment Variable", systemImage: "plus")
      }
    } header: {
      Text("Environment")
    } footer: {
      Text(
        """
        These values are added to Tatami's inherited environment for this hook. Tatami event variables take \
        precedence when names match.
        """
      )
    }
  }
}

// MARK: - HookTestSection

private struct HookTestSection: View {
  let store: StoreOf<HookEditorFeature>

  var body: some View {
    Section {
      if store.draft.event == .workspaceActivated {
        Picker("Workspace", selection: Binding(
          get: { store.testWorkspaceID },
          set: { store.send(.testWorkspaceChanged($0)) },
        )) {
          if store.testWorkspaces.isEmpty {
            Text("No normal workspaces").tag(Workspace.ID?.none)
          } else {
            ForEach(store.testWorkspaces) { workspace in
              Text(workspace.name).tag(Workspace.ID?.some(workspace.id))
            }
          }
        }
        .pickerStyle(.menu)
      }

      HStack {
        switch store.testStatus {
        case .running:
          ProgressView()
            .controlSize(.small)
          Text("Running test...")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Cancel Test") { store.send(.cancelTestButtonTapped) }

        default:
          Button {
            store.send(.testButtonTapped)
          } label: {
            Label("Run Test", systemImage: "play.fill")
          }
        }
      }

      HookTestResultView(status: store.testStatus)
    } header: {
      Text("Test")
    } footer: {
      Text("Runs the current draft once with a sample event. Testing does not save the hook.")
    }
  }
}

// MARK: - HookTestResultView

private struct HookTestResultView: View {
  let status: HookEditorFeature.TestStatus

  var body: some View {
    switch status {
    case .idle,
         .running:
      EmptyView()

    case .succeeded(let stdout, let stderr):
      Label("Test succeeded", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
      HookProcessOutput(stdout: stdout, stderr: stderr)

    case .failed(let message, let stdout, let stderr):
      Label(message, systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
        .textSelection(.enabled)
      HookProcessOutput(stdout: stdout, stderr: stderr)

    case .cancelled:
      Label("Test cancelled", systemImage: "stop.circle")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - HookProcessOutput

private struct HookProcessOutput: View {

  // MARK: Internal

  let stdout: String
  let stderr: String

  var body: some View {
    if !stdout.isEmpty {
      output("Standard Output", value: stdout)
    }
    if !stderr.isEmpty {
      output("Standard Error", value: stderr)
    }
  }

  // MARK: Private

  private func output(_ title: LocalizedStringResource, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(value)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .frame(maxHeight: 120)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
  }

}

extension HookEvent {
  fileprivate var localizedTitle: LocalizedStringResource {
    switch self {
    case .profileChanged:
      "Profile Changed"
    case .tatamiLaunched:
      "Tatami Launched"
    case .workspaceActivated:
      "Workspace Activated"
    case .hud:
      "HUD Published"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .profileChanged:
      "rectangle.stack.badge.person.crop"
    case .tatamiLaunched:
      "power"
    case .workspaceActivated:
      "square.stack.3d.up"
    case .hud:
      "rectangle.inset.filled"
    }
  }

  fileprivate var localizedPayloadDescription: LocalizedStringResource {
    switch self {
    case .profileChanged:
      "Provides the new profile and, when available, the previous profile."
    case .tatamiLaunched:
      "Provides the current profile when Tatami finishes launching."
    case .workspaceActivated:
      "Provides the profile, workspace, and, when available, the display."
    case .hud:
      "Provides the exact title, symbol, subtitle, duration, position, size, and display published to compact action feedback."
    }
  }

  fileprivate var jsonFields: String {
    let base = "schemaVersion, event, occurredAt, profile { id, name }"
    switch self {
    case .profileChanged:
      return base + ", previousProfile? { id, name }"
    case .tatamiLaunched:
      return base
    case .workspaceActivated:
      return base + ", workspace { id, name, kind }, display? { uuid?, name }"
    case .hud:
      return base
        + ", hud { title, symbolIconName?, subtitle?, durationMs, position, size }"
        + ", display? { uuid?, name }"
    }
  }

  fileprivate var environmentVariables: String {
    let base = "TATAMI_HOOK_ID, TATAMI_HOOK_EVENT, TATAMI_PROFILE_ID, TATAMI_PROFILE_NAME"
    switch self {
    case .profileChanged,
         .tatamiLaunched:
      return base

    case .workspaceActivated:
      return base
        + ", TATAMI_WORKSPACE_ID, TATAMI_WORKSPACE_NAME, TATAMI_WORKSPACE_KIND"
        + ", TATAMI_DISPLAY_NAME?, TATAMI_DISPLAY_UUID?"

    case .hud:
      return base
        + ", TATAMI_HUD_TITLE, TATAMI_HUD_SYMBOL_ICON_NAME?, TATAMI_HUD_SUBTITLE?"
        + ", TATAMI_HUD_DURATION_MS, TATAMI_HUD_POSITION, TATAMI_HUD_SIZE"
        + ", TATAMI_DISPLAY_NAME?, TATAMI_DISPLAY_UUID?"
    }
  }

  fileprivate var hasOptionalPayload: Bool {
    self != .tatamiLaunched
  }
}

extension HookEditorFeature.Mode {
  fileprivate var navigationTitle: LocalizedStringResource {
    switch self {
    case .add:
      "Add Hook"
    case .edit:
      "Edit Hook"
    }
  }
}

extension HookEditorFeature.ValidationIssue.Code {
  fileprivate var localizedMessage: LocalizedStringResource {
    switch self {
    case .definition(let code):
      code.localizedMessage
    case .duplicateEnvironmentKey:
      "Environment variable names must be unique"
    case .noActiveProfile:
      "A profile is required to run this hook"
    case .noWorkspace:
      "Choose a workspace for the test event"
    case .staleDefinition:
      "The hook changed while it was being edited"
    }
  }
}
