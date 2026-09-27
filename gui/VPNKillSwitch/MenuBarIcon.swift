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

    /// Settings key for the hazard-stripe background.
    static let stripesKey = "menuBarStripes"

    static func image(for power: PowerState, protection: Protection,
                      striped: Bool) -> NSImage {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(power)-\(protection)-\(dark)-\(striped)"
        if let cached = cache[key] { return cached }

        // Same tones as the window, resolved for the menu bar's own
        // appearance since an offscreen rendering does not inherit it.
        let tone: DaftarTone
        let text: String
        switch power {
        case .off:
            tone = power.tone;      text = "OFF"
        case .starting, .stopping:
            tone = power.tone;      text = "•••"
        case .on:
            tone = protection.tone
            switch protection {
            case .blocked: text = "CUT"
            case .armed:   text = "ARMED"
            default:       text = "ON"
            }
        }
        let renderer = striped
            ? ImageRenderer(content: AnyView(stripedLabel(tone: tone, text: text)))
            : ImageRenderer(content: AnyView(plainLabel(tone: tone, text: text, dark: dark)))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    private static func plainLabel(tone: DaftarTone, text: String, dark: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tone.fixed(dark: dark))
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(dark ? Color.white : Color.black)
        }
        .padding(.horizontal, 2)
        .frame(height: 16)
    }

    /// A hazard-striped capsule with the state on a dark plate inside it.
    /// The plate is what keeps the word legible: straight on the stripes,
    /// half of every letter sat on amber. It is the same on a light or a
    /// dark menu bar, so the dot uses the dark-theme tones.
    private static func stripedLabel(tone: DaftarTone, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tone.fixed(dark: true))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .frame(height: 13)
        .background(Capsule().fill(Color(red: 0x1C / 255, green: 0x0F / 255, blue: 0x0B / 255).opacity(0.9)))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(HazardStripes(band: 4, gap: 4.5).clipShape(Capsule()))
        .frame(height: 18)
        .fixedSize()
    }

    /// Appearance changes invalidate every cached rendering.
    static func flush() { cache.removeAll() }
}
