// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
// Offline OCR audit of delivered movies. No live screen or permission changes.
import AVFoundation
import Vision
import Foundation

let files = CommandLine.arguments.dropFirst()
guard !files.isEmpty else { fatalError("usage: swift audit-video.swift <movie.mp4> ...") }
Task {
  do {
    var report: [[String: Any]] = []
    var contaminated = false
    for path in files {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let duration = CMTimeGetSeconds(try await asset.load(.duration))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      var samples: [[String: Any]] = []
      for second in stride(from: 0.0, to: duration, by: 1.0) {
        let (image, actual) = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let matches = ["would like to record", "grant access to this application", "permissions needed", "see what's new in macos"]
          .filter { text.lowercased().contains($0) }
        if !matches.isEmpty { contaminated = true }
        samples.append(["second": CMTimeGetSeconds(actual), "matches": matches, "text": text])
      }
      report.append(["movie": path, "sampleIntervalSeconds": 1, "samples": samples])
    }
    let result: [String: Any] = ["status": contaminated ? "failed" : "passed", "scope": "OCR samples every second; does not replace playback review", "movies": report]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(contaminated ? 1 : 0)
  } catch {
    FileHandle.standardError.write(Data("audit-video: \(error)\n".utf8))
    exit(1)
  }
}
dispatchMain()
