// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - DemoCtlError

public enum DemoCtlError: Error, CustomStringConvertible {
  case packageRootNotFound
  case tatamiNotFound([String])
  case tatamiCLIMissing(String)
  case tatamiNotRunning(socket: String)
  case tatamiCommandFailed(command: String, message: String)
  case templateMissing(String)
  case unresolvedPlaceholders([String])
  case configInvalid([String])
  case bundlesMissing([String])
  case sceneNotFound(String, available: [String])
  case sceneStepFailed(index: Int, step: String, message: String)
  case waitTimedOut(what: String, seconds: Double)
  case recorderNotRunning
  case recorderAlreadyRunning(pid: Int32)
  case recorderFailedToStart(detail: String?)
  case recordingFailed([String])
  case defaultsSnapshotUnstamped(backup: String, stamp: String)
  case defaultsSnapshotForeign(captured: String, requested: String, backup: String)
  case defaultsSnapshotNotCleared(directory: String, domain: String, reason: String)
  case usage(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .packageRootNotFound:
      "could not locate the DemoLab package root; set DEMOLAB_ROOT to its path"

    case .tatamiNotFound(let searched):
      """
      Tatami.app not found. Looked in:
      \(searched.map { "  - \($0)" }.joined(separator: "\n"))
      Pass --tatami-app <path> or set DEMOLAB_TATAMI_APP.
      """

    case .tatamiCLIMissing(let path):
      "the Tatami bundle has no embedded CLI at \(path); reinstall or rebuild Tatami"

    case .tatamiNotRunning(let socket):
      """
      Tatami is not answering on \(socket).
      Run `democtl seed` first, or `democtl doctor` to see what is wrong.
      """

    case .tatamiCommandFailed(let command, let message):
      "tatami \(command): \(message)"

    case .templateMissing(let path):
      "config template not found at \(path)"

    case .unresolvedPlaceholders(let names):
      "config template still contains placeholders: \(names.joined(separator: ", "))"

    case .configInvalid(let problems):
      """
      the rendered config would be rejected or silently misread by Tatami:
      \(problems.map { "  - \($0)" }.joined(separator: "\n"))
      """

    case .bundlesMissing(let names):
      """
      these demo app bundles are missing: \(names.joined(separator: ", "))
      Run `./scripts/bundle-apps.sh` (or `democtl build`) first.
      """

    case .sceneNotFound(let name, let available):
      "no scene named \(name). Available: \(available.joined(separator: ", "))"

    case .sceneStepFailed(let index, let step, let message):
      "scene step \(index) (\(step)) failed: \(message)"

    case .waitTimedOut(let what, let seconds):
      "timed out after \(String(format: "%.1f", seconds))s waiting for \(what)"

    case .recorderNotRunning:
      "no recorder is running (no pid file, or the process is gone)"

    case .recorderAlreadyRunning(let pid):
      "a recorder is already running (pid \(pid)); stop it first"

    case .recorderFailedToStart(let detail):
      """
      the recorder exited during startup, before capture began\(detail.map { ": \($0)" } ?? "")
      Common causes: an unwritable --output path, a --display index that does not exist,
      no encoder for this resolution, or Screen Recording access revoked.
      """

    case .recordingFailed(let problems):
      """
      the take did not produce a usable recording:
      \(problems.map { "  - \($0)" }.joined(separator: "\n"))
      """

    case .defaultsSnapshotUnstamped(let backup, let stamp):
      """
      the defaults snapshot at \(backup) records no domain (\(stamp) is missing),
      so it cannot be imported safely: `defaults import` replaces whichever domain it is
      handed. Import it by hand with `defaults import <bundle-id> \(backup)`, then delete
      the snapshot directory.
      """

    case .defaultsSnapshotForeign(let captured, let requested, let backup):
      """
      the defaults snapshot at \(backup) was taken from \(captured), but this command
      targets \(requested). Importing it there would replace \(requested)'s real preferences.
      Finish the earlier shoot first: `democtl restore --tatami-app <the \(captured) bundle>`.
      """

    case .defaultsSnapshotNotCleared(let directory, let domain, let reason):
      """
      \(domain) was restored, but the snapshot at \(directory) could not be removed: \(reason)
      Delete it by hand — a later `democtl restore` would otherwise import it a second time.
      """

    case .usage(let message):
      message
    }
  }
}
