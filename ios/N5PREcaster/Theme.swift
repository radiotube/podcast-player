import SwiftUI

/// The web app's colors (index.html :root), so both look alike.
enum Theme {
    static let bg = Color(hex: 0x11181B)
    static let surface = Color(hex: 0x1A2327)
    static let surface2 = Color(hex: 0x243035)
    static let line = Color(hex: 0x2E3B41)
    static let fg = Color(hex: 0xE9EEF0)
    static let muted = Color(hex: 0x97A6AC)
    static let accent = Color(hex: 0xF2A93B)
    static let accentInk = Color(hex: 0x1D1405)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Small uppercase heading, like the web app's section labels.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.muted)
    }
}

/// A rounded chip: filled light when chosen, outlined when not.
struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Theme.bg : Theme.muted)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(Capsule().fill(on ? Theme.fg : Color.clear))
                .overlay(Capsule().stroke(on ? Theme.fg : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Two-way switch like the web app's segmented buttons.
struct Segmented: View {
    let options: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                Button { selection = i } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selection == i ? Theme.fg : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(selection == i ? Theme.surface2 : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
    }
}

/// The round orange play button.
struct PlayCircle: View {
    var size: CGFloat = 48
    var playing = false
    var ghost = false
    var body: some View {
        Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(ghost ? Theme.fg : Theme.accentInk)
            .frame(width: size, height: size)
            .background(Circle().fill(ghost ? Theme.surface2 : Theme.accent))
    }
}
