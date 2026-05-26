import AppKit
import Dependencies
import Foundation
import OSLog

/// Side-effect surface for "make this workspace active": showing/hiding
/// macOS apps via `NSRunningApplication`. Display-aware — hiding only
/// affects apps whose windows sit on the workspace's target display(s).
public struct WorkspaceManagerClient: Sendable {
  public var activate: @Sendable (ActivationRequest) async -> Void

  public init(activate: @escaping @Sendable (ActivationRequest) async -> Void) {
    self.activate = activate
  }
}

/// What the activation engine needs to flip "active" to a workspace.
public struct ActivationRequest: Sendable, Hashable {
  public var workspace: Workspace
  public var floatingApps: [FloatingApp]
  /// Display this activation targets. `nil` → all displays (dynamic mode).
  public var targetDisplay: DisplayName?
  /// Bundle identifiers belonging to *other* workspaces on the same display.
  /// These are the apps we need to hide. Anything not in this set (and not
  /// in `workspace.apps` or `floatingApps`) is treated as "unassigned" and
  /// left visible.
  public var displayPeerBundleIds: Set<String>
  public var setFocus: Bool

  public init(
    workspace: Workspace,
    floatingApps: [FloatingApp],
    targetDisplay: DisplayName?,
    displayPeerBundleIds: Set<String> = [],
    setFocus: Bool = true
  ) {
    self.workspace = workspace
    self.floatingApps = floatingApps
    self.targetDisplay = targetDisplay
    self.displayPeerBundleIds = displayPeerBundleIds
    self.setFocus = setFocus
  }
}

extension WorkspaceManagerClient: DependencyKey {
  public static let liveValue: WorkspaceManagerClient = .live()

  public static let testValue = WorkspaceManagerClient(activate: { _ in })
  public static let previewValue = WorkspaceManagerClient(activate: { request in
    logger.debug("[preview] activate \(request.workspace.name)")
  })

  static func live() -> WorkspaceManagerClient {
    WorkspaceManagerClient(
      activate: { request in
        let workspace = request.workspace
        let workspaceBundleIds = Set(workspace.apps.map(\.bundleIdentifier))
        let floatingBundleIds = Set(request.floatingApps.map(\.bundleIdentifier))
        let appsToHide = request.displayPeerBundleIds
          .subtracting(workspaceBundleIds)
          .subtracting(floatingBundleIds)

        await MainActor.run {
          let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
          }

          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }

            if workspaceBundleIds.contains(bundleId) || floatingBundleIds.contains(bundleId) {
              if app.isHidden {
                app.unhide()
              }
            } else if appsToHide.contains(bundleId), !app.isHidden {
              app.hide()
            }
            // Apps not in any workspace on this display: leave alone.
          }

          if request.setFocus, let focusBundleId = workspace.appToFocusBundleId
             ?? workspace.apps.last?.bundleIdentifier
          {
            running.first { $0.bundleIdentifier == focusBundleId }?
              .activate(options: [.activateIgnoringOtherApps])
          } else if request.setFocus {
            running.first { workspaceBundleIds.contains($0.bundleIdentifier ?? "") }?
              .activate(options: [.activateIgnoringOtherApps])
          }
        }

        let displayLabel = request.targetDisplay?.rawValue ?? "any"
        logger.info(
          """
          Activated workspace '\(workspace.name)' on display '\(displayLabel)': \
          show=\(workspaceBundleIds.count) float=\(floatingBundleIds.count) \
          hide=\(appsToHide.count)
          """
        )
      }
    )
  }
}

extension DependencyValues {
  public var workspaceManager: WorkspaceManagerClient {
    get { self[WorkspaceManagerClient.self] }
    set { self[WorkspaceManagerClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WorkspaceManager")
