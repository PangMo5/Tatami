// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
// Offline visual text checks; no live capture or permission changes.
import AVFoundation
import Vision
import Foundation

struct Cue: Decodable { let track: String; let text: String; let start: Double; let end: Double }
struct Timeline: Decodable { let events: [Cue] }
func normalized(_ text: String) -> [Character] { Array(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
func similarity(_ expected: String, _ observed: String) -> Double {
  let a = normalized(expected), b = normalized(observed)
  guard !a.isEmpty else { return 1 }
  var previous = [Int](repeating: 0, count: b.count + 1)
  for character in a {
    var row = [Int](repeating: 0, count: b.count + 1)
    for (index, other) in b.enumerated() {
      row[index + 1] = character == other ? previous[index] + 1 : max(previous[index + 1], row[index])
    }
    previous = row
  }
  return Double(previous.last ?? 0) / Double(a.count)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let cpuOnly = arguments.contains("--cpu-only")
arguments.removeAll { $0 == "--cpu-only" }
let openingOnly = arguments.contains("--opening-only")
arguments.removeAll { $0 == "--opening-only" }
let languages = ["en":"en-US", "ko":"ko-KR", "ja":"ja-JP", "zh-Hans":"zh-Hans", "zh-Hant":"zh-Hant"]
var locale = "en"
if let index = arguments.firstIndex(of: "--locale") {
  guard arguments.indices.contains(index + 1), languages[arguments[index + 1]] != nil else { fatalError("unsupported OCR locale") }
  locale = arguments[index + 1]; arguments.removeSubrange(index...index + 1)
}
guard !arguments.isEmpty else { fatalError("usage: audit-video [--cpu-only] --locale <locale> <movie.mp4> ...") }
let files = arguments
Task {
  do {
    var report: [[String: Any]] = []; var failed = false
    for path in files {
      let url = URL(fileURLWithPath: path)
      let asset = AVURLAsset(url: url)
      let duration = CMTimeGetSeconds(try await asset.load(.duration))
      let timelineURL = url.deletingLastPathComponent().appendingPathComponent("evidence")
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".edited.timeline.json")
      let timeline = openingOnly ? Timeline(events: []) : try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: timelineURL))
      let captions = timeline.events.filter { $0.track == "caption" && !$0.text.isEmpty }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      let midpoints = captions.filter { $0.end - $0.start >= 0.4 }.map { (($0.start + $0.end) / 2 * 30).rounded() / 30 }
      let seconds = openingOnly ? [0.0] : Set(Array(stride(from: 0.0, to: duration, by: 1.0)) + midpoints).sorted()
      var samples: [[String: Any]] = []; var checks: [[String: Any]] = []
      for second in seconds where second < duration {
        let (image, actual) = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
        let at = CMTimeGetSeconds(actual)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if cpuOnly {
          if #available(macOS 14.0, *) {
            for (stage, devices) in try request.supportedComputeStageDevices {
              guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else {
                throw NSError(domain: "DemoLab.OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "CPU execution is unavailable for OCR stage \(stage)"])
              }
              request.setComputeDevice(cpu, for: stage)
            }
          } else {
            throw NSError(domain: "DemoLab.OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Explicit OCR compute selection requires macOS 14 or later"])
          }
        }
        request.recognitionLanguages = locale == "en" ? ["en-US"] : [languages[locale]!, "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let matches = ["would like to record", "grant access to this application", "permissions needed", "see what's new in macos"]
          .filter { text.lowercased().contains($0) }
        if !matches.isEmpty { failed = true }
        samples.append(["second": at, "matches": matches, "text": text])
        if let cue = captions.last(where: { at >= $0.start + 0.15 && at <= $0.end - 0.15 }) {
          let band = image.height < 1000 ? 0.30 : 0.21
          let fragments = observations.filter { $0.boundingBox.maxY <= band && $0.boundingBox.minY >= 0.035 }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
          // Vision can split one caption into left/right fragments with
          // slightly different baselines. Read each line left to right.
          var lines: [[VNRecognizedTextObservation]] = []
          for fragment in fragments {
            if let previous = lines.last?.first, abs(previous.boundingBox.midY - fragment.boundingBox.midY) < 0.012 {
              lines[lines.count - 1].append(fragment)
            } else { lines.append([fragment]) }
          }
          let overlayText = lines.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
          let score = similarity(cue.text, overlayText)
          let passed = score >= 0.70
          if !passed { failed = true }
          checks.append(["second": at, "expected": cue.text, "observed": overlayText, "matchRatio": score, "passed": passed])
        }
      }
      if !openingOnly && checks.isEmpty { failed = true }
      report.append(["movie": path, "sampleIntervalSeconds": 1, "samples": samples, "captionChecks": checks])
    }
    let result: [String: Any] = ["locale": locale, "status": failed ? "failed" : "passed", "computeDevice": cpuOnly ? "cpu" : "automatic",
      "scope": "OCR every second plus caption midpoints; checks permission phrases and readable overlaid narration; does not replace playback review", "movies": report]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
    exit(failed ? 1 : 0)
  } catch {
    FileHandle.standardError.write(Data("audit-video: \(error)\n".utf8)); exit(1)
  }
}
dispatchMain()
