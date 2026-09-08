// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Executes synchronous IPC/I/O without occupying the main actor or a Swift
/// cooperative executor. Callers retain cancellation and commit ownership:
/// cancelling an await must not imply that an already-started write rolled back.
struct BlockingWorkQueue: Sendable {

  // MARK: Lifecycle

  init(label: String, qos: DispatchQoS = .userInitiated) {
    queue = DispatchQueue(label: label, qos: qos)
  }

  // MARK: Internal

  func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: operation()) }
    }
  }

  func runThrowing<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }

  // MARK: Private

  private let queue: DispatchQueue

}
