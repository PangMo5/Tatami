// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct CanvasView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  var body: some View {
    DemoWindow {
      DemoTitle("Launch page", symbol: "square.stack.3d.up", accent: .purple, subtitle: "Canvas / Live preview")
      Spacer()
      Button("Export") { exportPreview() }.accessibilityIdentifier("canvas.export")
      ForEach(["cobalt", "sand", "forest"], id: \.self) { theme in
        Button(theme.capitalized) { session.update { $0.designTheme = theme } }
          .accessibilityIdentifier("canvas.\(theme)")
          .buttonStyle(.bordered)
          .tint(session.story.designTheme == theme ? Color.purple : Color.gray)
      }
    } content: {
      ScrollView {
        PagePreview(headline: session.story.headline, bodyText: session.story.body, theme: session.story.designTheme)
      }.background(Color(red: 0.08, green: 0.09, blue: 0.13))
    } status: {
      StoryStatus("Live from the saved draft", error: session.error)
      Spacer()
      Text("\(session.story.designTheme.capitalized) · Revision \(session.story.revision)")
    }.onAppear { session.start() }
  }
  private func exportPreview() {
    let renderer=ImageRenderer(content:PagePreview(headline:session.story.headline,bodyText:session.story.body,theme:session.story.designTheme).frame(width:1280).background(Color(red:0.08,green:0.09,blue:0.13)))
    guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {session.error="Could not render the preview";return}
    do {
      try png.write(to:DemoControl.directory.appendingPathComponent("launch-preview.png"),options:.atomic)
      session.update {story in story.exported=true;if let index=story.tasks.firstIndex(where:{$0.id==2}) {story.tasks[index].done=true}}
    } catch {session.error=String(describing:error)}
  }

}
private struct PagePreview: View {
  let headline: String
  let bodyText: String
  let theme: String
  var tint: Color {
    switch theme {
    case "sand": Color(red: 0.91, green: 0.80, blue: 0.59)
    case "forest": Color(red: 0.44, green: 0.76, blue: 0.62)
    default: Color(red: 0.47, green: 0.60, blue: 1.0)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      HStack {
        Label("FORM / FIELD", systemImage: "square.grid.2x2.fill").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("Product     Journal").font(.system(size: 12))
      }.foregroundStyle(.white.opacity(0.65))
      Text("ROOM TO THINK").font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(tint).padding(.top, 32)
      Text(headline).font(.system(size: 48, weight: .semibold)).tracking(-2).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
      Text(bodyText).font(.system(size: 18)).lineSpacing(6).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: 640, alignment: .leading)
      HStack { Text("Find your flow").font(.system(size: 15, weight: .semibold)); Image(systemName: "arrow.up.right") }
        .foregroundStyle(.black).padding(.horizontal, 22).padding(.vertical, 14).background(tint, in: Capsule())
      WorkspaceArtwork(tint: tint).frame(height: 240).padding(.top, 12)
      HStack(spacing: 26) {
        PreviewDetail("01", "A place to begin", "Bring the tools for this task together.")
        PreviewDetail("02", "A place to return", "Keep the arrangement that works for you.")
      }
    }.padding(40).frame(maxWidth: .infinity, alignment: .leading)
  }
}
private struct WorkspaceArtwork: View {
  let tint: Color
  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 15) {
          HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.28)).frame(width: 6,height: 6) } }
          RoundedRectangle(cornerRadius: 5).fill(tint).frame(width: proxy.size.width * 0.22, height: 16)
          RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15)).frame(height: 8)
          RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.10)).frame(width: proxy.size.width * 0.25,height: 8)
          Spacer()
          Text("YOUR WORK").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(.white.opacity(0.4))
        }.padding(24).frame(maxWidth: .infinity).background(.white.opacity(0.06), in: .rect(cornerRadius: 18))
        VStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 18).fill(tint.opacity(0.22)).overlay(Image(systemName:"sparkle").font(.system(size:40)).foregroundStyle(tint))
          RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)).overlay(Image(systemName:"text.alignleft").font(.system(size:28)).foregroundStyle(.white.opacity(0.45)))
        }.frame(width: proxy.size.width * 0.35)
      }
    }
  }
}
private struct PreviewDetail: View {
  let number: String; let title: String; let description: String
  init(_ number: String,_ title: String,_ description: String) { self.number=number;self.title=title;self.description=description }
  var body: some View {
    VStack(alignment: .leading,spacing:10) {
      Text(number).font(.system(size:12)).foregroundStyle(.white.opacity(0.4))
      Text(title).font(.system(size:18,weight:.medium)).foregroundStyle(.white)
      Text(description).font(.system(size:14)).foregroundStyle(.white.opacity(0.55))
    }.frame(maxWidth:.infinity,alignment:.leading)
  }
}
