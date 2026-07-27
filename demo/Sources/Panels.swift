import SwiftUI

/// One faux "app" shown in its own window. Themed to look like a developer's
/// real setup so a Tatami promo recording reads as authentic while staying
/// clean and branded.
enum DemoApp: String, CaseIterable {
  case terminal, code, safari, notes
  case figma, photos, messages, mail, calendar

  /// Resolved from the bundle's `TatamiDemoPanel` Info.plist key — each demo
  /// app ships the same binary but a distinct bundle id + panel, so they're
  /// separate apps Tatami can assign to different workspaces.
  static var current: DemoApp {
    (Bundle.main.object(forInfoDictionaryKey: "TatamiDemoPanel") as? String)
      .flatMap(DemoApp.init(rawValue:)) ?? .terminal
  }

  var title: String {
    switch self {
    case .terminal: "Terminal"
    case .code: "Code"
    case .safari: "Safari"
    case .notes: "Notes"
    case .figma: "Figma"
    case .photos: "Photos"
    case .messages: "Messages"
    case .mail: "Mail"
    case .calendar: "Calendar"
    }
  }

  var size: CGSize {
    switch self {
    case .terminal: CGSize(width: 720, height: 460)
    case .code: CGSize(width: 820, height: 520)
    case .safari: CGSize(width: 900, height: 560)
    case .notes: CGSize(width: 640, height: 460)
    case .figma: CGSize(width: 860, height: 540)
    case .photos: CGSize(width: 780, height: 520)
    case .messages: CGSize(width: 640, height: 520)
    case .mail: CGSize(width: 860, height: 540)
    case .calendar: CGSize(width: 820, height: 540)
    }
  }

  @MainActor @ViewBuilder var view: some View {
    switch self {
    case .terminal: TerminalPanel()
    case .code: CodePanel()
    case .safari: SafariPanel()
    case .notes: NotesPanel()
    case .figma: FigmaPanel()
    case .photos: PhotosPanel()
    case .messages: MessagesPanel()
    case .mail: MailPanel()
    case .calendar: CalendarPanel()
    }
  }
}

// MARK: - Terminal

private struct TerminalPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      line("~/Tatami", "tatami list-workspaces")
      Group {
        plain("Browser"); plain("Coding"); plain("Terminal"); plain("Figma"); plain("Notion")
      }
      line("~/Tatami", "tatami activate Coding")
      (Text("Activated: ").foregroundStyle(.secondary) + Text("Coding").foregroundStyle(.green))
        .font(font)
      HStack(spacing: 0) {
        prompt("~/Tatami")
        Text("▮").foregroundStyle(.white.opacity(0.85))
      }
      Spacer()
    }
    .font(font)
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(red: 0.05, green: 0.05, blue: 0.06))
  }

  private var font: Font { .system(size: 14, weight: .regular, design: .monospaced) }
  private func prompt(_ path: String) -> some View {
    (Text(path + " ").foregroundStyle(Color(red: 0.4, green: 0.8, blue: 1))
      + Text("❯ ").foregroundStyle(.green)).font(font)
  }
  private func line(_ path: String, _ cmd: String) -> some View {
    HStack(spacing: 0) { prompt(path); Text(cmd).foregroundStyle(.white) }
  }
  private func plain(_ s: String) -> some View {
    Text(s).foregroundStyle(.white.opacity(0.8))
  }
}

// MARK: - Code

private struct CodePanel: View {
  // Token colors loosely matching a dark editor theme.
  private let kw = Color(red: 0.78, green: 0.57, blue: 0.98)   // keyword
  private let ty = Color(red: 0.4, green: 0.85, blue: 0.86)    // type
  private let fn = Color(red: 0.51, green: 0.78, blue: 0.98)   // function
  private let st = Color(red: 0.6, green: 0.84, blue: 0.5)     // string/case
  private let cm = Color(white: 0.45)                          // comment
  private let tx = Color(white: 0.86)                          // plain

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .trailing, spacing: 4) {
        ForEach(1...lines.count, id: \.self) { Text("\($0)").foregroundStyle(.white.opacity(0.25)) }
      }
      .padding(.vertical, 20).padding(.horizontal, 14)
      .background(Color(white: 0.1))

      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(lines.enumerated()), id: \.offset) { $0.element }
        Spacer()
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .font(.system(size: 14, weight: .regular, design: .monospaced))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.12, green: 0.12, blue: 0.16))
  }

  private var lines: [Text] {
    [
      Text("// Insert a window into the BSP tree.").foregroundStyle(cm),
      Text("func ").foregroundStyle(kw) + Text("insert").foregroundStyle(fn)
        + Text("(_ window: ").foregroundStyle(tx) + Text("Window").foregroundStyle(ty)
        + Text(", near anchor: ").foregroundStyle(tx) + Text("Window").foregroundStyle(ty)
        + Text(") -> ").foregroundStyle(tx) + Text("BSPNode").foregroundStyle(ty)
        + Text(" {").foregroundStyle(tx),
      Text("  let ").foregroundStyle(kw) + Text("axis = workArea.isWide ? ").foregroundStyle(tx)
        + Text(".vertical").foregroundStyle(st) + Text(" : ").foregroundStyle(tx)
        + Text(".horizontal").foregroundStyle(st),
      Text("  return ").foregroundStyle(kw)
        + Text("node.splitting(anchor, with: window, along: axis)").foregroundStyle(tx),
      Text("}").foregroundStyle(tx),
    ]
  }
}

// MARK: - Safari

private struct SafariPanel: View {
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "chevron.left").foregroundStyle(.secondary)
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        HStack(spacing: 6) {
          Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
          Text("pangmo5.dev/Tatami").foregroundStyle(.primary)
          Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(white: 0.5, opacity: 0.15), in: Capsule())
        .frame(maxWidth: 420)
        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
        Image(systemName: "plus").foregroundStyle(.secondary)
      }
      .font(.system(size: 13))
      .padding(.horizontal, 16).padding(.vertical, 12)
      .background(.regularMaterial)
      Divider()
      VStack(spacing: 18) {
        Spacer()
        Image(systemName: "square.grid.2x2.fill")
          .font(.system(size: 52)).foregroundStyle(.tint)
        Text("Tatami").font(.system(size: 46, weight: .semibold))
        Text("A macOS workspace manager,\nwith BSP window tiling.")
          .multilineTextAlignment(.center)
          .font(.system(size: 17)).foregroundStyle(.secondary)
        TiledGlyph().frame(width: 240, height: 120).padding(.top, 8)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
    }
    .tint(Color(red: 0.16, green: 0.59, blue: 1))
  }
}

/// A tiny dwindle-layout glyph (one big tile + two stacked) for the hero.
private struct TiledGlyph: View {
  var body: some View {
    GeometryReader { geo in
      let g: CGFloat = 6
      let w = geo.size.width, h = geo.size.height
      let leftW = (w - g) * 0.6
      ZStack(alignment: .topLeading) {
        tile.frame(width: leftW, height: h)
        tile.frame(width: w - leftW - g, height: (h - g) / 2).offset(x: leftW + g)
        tile.frame(width: w - leftW - g, height: (h - g) / 2).offset(x: leftW + g, y: (h - g) / 2 + g)
      }
    }
  }
  private var tile: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(Color.accentColor.opacity(0.16))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5))
  }
}

// MARK: - Notes

private struct NotesPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Demo shot list").font(.system(size: 22, weight: .semibold))
      Text("June 2026").foregroundStyle(.secondary).font(.system(size: 13))
      Divider().padding(.vertical, 2)
      check("Open a window — it tiles itself", true)
      check("⌘N adds another, splits the focused tile", true)
      check("Swap, zoom, rotate with vim keys", false)
      check("Switch workspaces", false)
      check("Multi-monitor, per display", false)
      Spacer()
    }
    .padding(26)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(red: 0.99, green: 0.97, blue: 0.86))
    .foregroundStyle(Color(red: 0.2, green: 0.18, blue: 0.1))
  }

  private func check(_ s: String, _ done: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? Color(red: 0.9, green: 0.7, blue: 0.2) : .secondary)
      Text(s).strikethrough(done, color: .secondary)
        .foregroundStyle(done ? .secondary : .primary)
    }
    .font(.system(size: 16))
  }
}

// MARK: - Figma (Design workspace)

private struct FigmaPanel: View {
  var body: some View {
    HStack(spacing: 0) {
      // Layers sidebar.
      VStack(alignment: .leading, spacing: 10) {
        Text("Layers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        ForEach(["Hero", "Card", "Button", "Icon"], id: \.self) { name in
          HStack(spacing: 8) {
            Image(systemName: "square.on.square").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(name).font(.system(size: 13))
          }
        }
        Spacer()
      }
      .padding(14).frame(width: 160, alignment: .topLeading)
      .background(Color(white: 0.16)).foregroundStyle(.white)

      // Canvas.
      ZStack {
        Color(white: 0.22)
        VStack(spacing: 18) {
          RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
            colors: [Color(red: 0.4, green: 0.5, blue: 1), Color(red: 0.7, green: 0.4, blue: 1)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 300, height: 150)
          HStack(spacing: 18) {
            Circle().fill(Color(red: 1, green: 0.5, blue: 0.4)).frame(width: 80, height: 80)
            RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.3, green: 0.8, blue: 0.6))
              .frame(width: 180, height: 80)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: - Photos (Design workspace)

private struct PhotosPanel: View {
  private let swatches: [[Color]] = [
    [Color(red: 1, green: 0.6, blue: 0.4), Color(red: 1, green: 0.4, blue: 0.5)],
    [Color(red: 0.4, green: 0.7, blue: 1), Color(red: 0.5, green: 0.5, blue: 0.95)],
    [Color(red: 0.5, green: 0.85, blue: 0.6), Color(red: 0.3, green: 0.7, blue: 0.7)],
    [Color(red: 1, green: 0.8, blue: 0.4), Color(red: 1, green: 0.6, blue: 0.3)],
    [Color(red: 0.8, green: 0.6, blue: 0.95), Color(red: 0.6, green: 0.5, blue: 0.9)],
    [Color(red: 0.6, green: 0.8, blue: 0.85), Color(red: 0.4, green: 0.6, blue: 0.8)],
  ]
  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
        ForEach(0..<12, id: \.self) { i in
          RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: swatches[i % swatches.count],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(1.4, contentMode: .fit)
        }
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

// MARK: - Messages (Chat workspace)

private struct MessagesPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      bubble("Did Tatami tile that for you?", incoming: true)
      bubble("Yep — opened the window and it just snapped in", incoming: false)
      bubble("⌘ a couple keys and it's a full BSP layout", incoming: false)
      bubble("No SIP, no scripting?", incoming: true)
      bubble("None. Native app.", incoming: false)
      Spacer()
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private func bubble(_ text: String, incoming: Bool) -> some View {
    HStack {
      if !incoming { Spacer(minLength: 60) }
      Text(text)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .foregroundStyle(incoming ? Color.primary : .white)
        .background(incoming ? Color(white: 0.5, opacity: 0.22) : Color(red: 0.16, green: 0.59, blue: 1),
                    in: RoundedRectangle(cornerRadius: 17))
      if incoming { Spacer(minLength: 60) }
    }
    .font(.system(size: 15))
  }
}

// MARK: - Mail (Chat workspace)

private struct MailPanel: View {
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
          VStack(alignment: .leading, spacing: 3) {
            Text(r.0).font(.system(size: 13, weight: .semibold))
            Text(r.1).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
          }
          .padding(.horizontal, 14).padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(i == 0 ? Color(red: 0.16, green: 0.59, blue: 1).opacity(0.15) : .clear)
          Divider()
        }
        Spacer()
      }
      .frame(width: 260)
      .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        Text("Tatami 1.2.1 is out").font(.system(size: 20, weight: .semibold))
        Text("from  Sparkle Updates").font(.system(size: 12)).foregroundStyle(.secondary)
        Divider()
        Text("This release fixes detection of windows that hide instead of close, "
          + "so apps like Discord tile and untile cleanly. Update from the menu bar.")
          .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
        Spacer()
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor))
    }
  }
  private let rows: [(String, String)] = [
    ("Sparkle Updates", "Tatami 1.2.1 is out"),
    ("GitHub", "Your release v1.2.1 published"),
    ("Homebrew", "tatami 1.2.1 bottled"),
    ("PangMo5", "Re: demo footage"),
  ]
}

// MARK: - Calendar (Chat workspace)

private struct CalendarPanel: View {
  private let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(days, id: \.self) { d in
          Text(d).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 10)
      Divider()
      GeometryReader { geo in
        let colW = geo.size.width / CGFloat(days.count)
        ZStack(alignment: .topLeading) {
          Color(nsColor: .textBackgroundColor)
          event("Standup", colW * 0 + 4, 24, colW - 8, 50, .blue)
          event("Record demo", colW * 2 + 4, 70, colW - 8, 110, .orange)
          event("Ship 1.2.1", colW * 4 + 4, 40, colW - 8, 80, .green)
          event("Review", colW * 1 + 4, 150, colW - 8, 60, .purple)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func event(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ c: Color) -> some View {
    Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
      .padding(6).frame(width: w, height: h, alignment: .topLeading)
      .background(c.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
      .offset(x: x, y: y)
  }
}
