import AppKit
import Dependencies
import Foundation
import OSLog

/// Side-effect surface for "make this workspace active": showing/hiding
/// macOS apps via `NSRunningApplication`. Future passes will layer
/// display routing, focus history, PiP corner-hiding, and transitions
/// on top of this dependency without changing the reducer.
public struct WorkspaceManagerClient: Sendable {
  public var activate: @Sendable (ActivationRequest) async -> Void

  public init(activate: @escaping @Sendable (ActivationRequest) async -> Void) {
    self.activate = activate
  }
}

/// What the activation engine needs to flip "active" to a workspace.
///
/// Kept as a value type so it is trivially Sendable and can be diffed
/// in tests.
public struct ActivationRequest: Sendable, Hashable {
  public var workspace: Workspace
  public var floatingApps: [FloatingApp]
  public var setFocus: Bool

  public init(workspace: Workspace, floatingApps: [FloatingApp], setFocus: Bool = true) {
    self.workspace = workspace
    self.floatingApps = floatingApps
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
        let keepVisible = workspaceBundleIds.union(floatingBundleIds)

        await MainActor.run {
          let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
          }

          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }

            if workspaceBundleIds.contains(bundleId) {
              // Workspace app — raise (unhides + brings forward) without stealing focus.
              if app.isHidden {
                app.unhide()
              }
            } else if floatingBundleIds.contains(bundleId) {
              // Floating app — ensure visible, do not focus.
              if app.isHidden {
                app.unhide()
              }
            } else {
              // Not in this workspace — hide.
              if !app.isHidden {
                app.hide()
              }
            }
          }

          if request.setFocus, let focusBundleId = workspace.appToFocusBundleId
             ?? workspace.apps.last?.bundleIdentifier
          {
            let target = running.first { $0.bundleIdentifier == focusBundleId }
            target?.activate(options: [.activateIgnoringOtherApps])
          } else if request.setFocus {
            // No explicit focus — front-most workspace app.
            let app = running.first { workspaceBundleIds.contains($0.bundleIdentifier ?? "") }
            app?.activate(options: [.activateIgnoringOtherApps])
          }
        }

        logger.info(
          "Activated workspace '\(workspace.name)': show=\(workspaceBundleIds.count) float=\(floatingBundleIds.count)"
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
