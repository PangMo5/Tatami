import Dependencies
import Foundation
import KeyboardShortcuts

/// Side-effect surface for registering global keyboard shortcuts. Wraps
/// `KeyboardShortcuts` so the reducer can register a flat list of
/// (workspaceId, shortcut) bindings and subscribe to fire events.
public struct HotKeysClient: Sendable {
  public var register: @Sendable ([WorkspaceHotKeyBinding]) async -> Void
  public var events: @Sendable () -> AsyncStream<WorkspaceHotKeyEvent>

  public init(
    register: @escaping @Sendable ([WorkspaceHotKeyBinding]) async -> Void,
    events: @escaping @Sendable () -> AsyncStream<WorkspaceHotKeyEvent>
  ) {
    self.register = register
    self.events = events
  }
}

public struct WorkspaceHotKeyBinding: Sendable, Hashable {
  public var workspaceId: Workspace.ID
  public var hotKey: HotKey

  public init(workspaceId: Workspace.ID, hotKey: HotKey) {
    self.workspaceId = workspaceId
    self.hotKey = hotKey
  }
}

public struct WorkspaceHotKeyEvent: Sendable, Hashable {
  public var workspaceId: Workspace.ID

  public init(workspaceId: Workspace.ID) {
    self.workspaceId = workspaceId
  }
}

extension HotKeysClient: DependencyKey {
  public static let liveValue: HotKeysClient = {
    let center = HotKeysCenter()
    return HotKeysClient(
      register: { bindings in
        await center.register(bindings)
      },
      events: { center.events }
    )
  }()

  public static let testValue = HotKeysClient(
    register: { _ in },
    events: { AsyncStream { _ in } }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var hotKeys: HotKeysClient {
    get { self[HotKeysClient.self] }
    set { self[HotKeysClient.self] = newValue }
  }
}

/// Manages the live KeyboardShortcuts registrations across the lifetime
/// of the process. `register` is `@MainActor` because KeyboardShortcuts
/// is itself main-actor; the surrounding state is plumbed via
/// `@unchecked Sendable` because all mutation happens through that hop.
private final class HotKeysCenter: @unchecked Sendable {
  let events: AsyncStream<WorkspaceHotKeyEvent>
  private let continuation: AsyncStream<WorkspaceHotKeyEvent>.Continuation
  private var registeredNames: [KeyboardShortcuts.Name] = []

  init() {
    var continuation: AsyncStream<WorkspaceHotKeyEvent>.Continuation!
    self.events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  @MainActor
  func register(_ bindings: [WorkspaceHotKeyBinding]) {
    if !registeredNames.isEmpty {
      // No per-name handler removal in KeyboardShortcuts — reset all
      // workspace handlers and re-install below.
      KeyboardShortcuts.removeAllHandlers()
    }

    var newNames: [KeyboardShortcuts.Name] = []
    for binding in bindings {
      let name = KeyboardShortcuts.Name("tatami.workspace.\(binding.workspaceId.uuidString)")
      KeyboardShortcuts.setShortcut(binding.hotKey.shortcut, for: name)
      let workspaceId = binding.workspaceId
      let continuation = continuation
      KeyboardShortcuts.onKeyDown(for: name) {
        continuation.yield(WorkspaceHotKeyEvent(workspaceId: workspaceId))
      }
      newNames.append(name)
    }

    registeredNames = newNames
  }
}
