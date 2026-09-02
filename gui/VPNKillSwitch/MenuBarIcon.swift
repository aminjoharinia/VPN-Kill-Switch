import SwiftUI
import AppKit

/// Renders the menu bar label — a coloured dot plus a short word.
///
/// The label is drawn to an NSImage with `isTemplate = false` on purpose.
/// A template image is recoloured by the system to a single flat tone,
/// which would throw away the red/orange/green that carries the entire
/// meaning here. The cost of opting out is that the text no longer
/// auto-inverts, so the label colour is chosen from the current menu bar
/// appearance and re-rendered whenever that changes.
@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for power: PowerState, protection: Protection) -> NSImage {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(power)-\(protection)-\(dark)"
        if let cached = cache[key] { return cached }

        let dot: Color
        let text: String
        switch power {
        case .off:
            dot = .red;    text = "OFF"
        case .starting:
            dot = .orange; text = "•••"
        case .stopping:
            dot = .orange; text = "•••"
        case .on:
            switch protection {
            case .blocked: dot = .red;    text = "CUT"
            case .armed:   dot = .blue;   text = "ARMED"
            default:       dot = .green;  text = "ON"
            }
        }

        let label = HStack(spacing: 4) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(dark ? Color.white : Color.black)
        }
        .padding(.horizontal, 2)
        .frame(height: 16)

        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    /// Appearance changes invalidate every cached rendering.
    static func flush() { cache.removeAll() }
}
