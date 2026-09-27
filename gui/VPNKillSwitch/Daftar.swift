import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// Daftar (دفتر) — the design language shared with the Hesabak accounting app
// (LedgerUi.dart / ReportUi.dart), translated to SwiftUI:
//
//   * pages sit on the plain window surface; tints are alpha over that
//     surface, never fixed pastels, so nothing glows in dark mode;
//   * colour carries meaning only, and every tone is a light/dark pair
//     picked for contrast on that theme's surface;
//   * a header is an icon tile, a bold title, a muted subtitle and one
//     headline figure in a tinted pill;
//   * stat tiles are an icon chip, a muted label and a true-bold figure;
//   * tables have a muted header on a raised strip, light zebra rows,
//     hairline dividers and a rounded frame.
// ---------------------------------------------------------------------------

/// One colour as a light/dark pair.
struct DaftarTone: Equatable {
    let light: UInt32
    let dark: UInt32

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// Follows the appearance of whatever it is drawn in.
    var color: Color {
        let light = Self.ns(self.light), dark = Self.ns(self.dark)
        return Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// For offscreen renderings (the menu bar label), where the appearance
    /// is known but not inherited.
    func fixed(dark isDark: Bool) -> Color { Color(nsColor: Self.ns(isDark ? dark : light)) }
}

enum Daftar {
    // Tones, as in LedgerTones. The light halves sit a step darker than
    // Daftar's defaults: on this app's grey light surface the 700s washed
    // out. The accent is this app's own dark amber, taken from the icon.
    static let accent  = DaftarTone(0x8F5400, 0xF2B94E)   // dark amber / amber
    static let good    = DaftarTone(0x2E7D32, 0x81C784)   // green 800 / 300
    static let danger  = DaftarTone(0xC62828, 0xEF7B7B)   // red 800 / 300
    // Pushed toward red so "caution" never reads as the amber accent.
    static let warning = DaftarTone(0xD84315, 0xFF8A65)   // deep orange 800 / 300
    static let armed   = DaftarTone(0x1565C0, 0x8CC4F0)   // blue 800 / "purchase"
    static let muted   = DaftarTone(0x5F6368, 0x9E9E9E)

    /// The icon's hazard stripes.
    static let hazardAmber = DaftarTone(0xF2CF55, 0xF2CF55)
    static let hazardDark  = DaftarTone(0x3B2B26, 0x3B2B26)

    /// Alpha steps from LedgerUi: tile 34/255, chip 36/255, pill 26/255,
    /// pill border 70/255. These are the dark-theme values; `tint(_:)`
    /// strengthens them on the light theme, where they were too faint to
    /// tell a tile from the page.
    static let tileAlpha   = 0.13
    static let chipAlpha   = 0.14
    static let pillAlpha   = 0.10
    static let borderAlpha = 0.27
    static let lightBoost  = 1.7

    private static func overlay(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(dark)
                : NSColor.black.withAlphaComponent(light)
        })
    }

    private static func dynamic(light: UInt32, dark: NSColor) -> Color {
        let l = NSColor(srgbRed: CGFloat((light >> 16) & 0xFF) / 255,
                        green: CGFloat((light >> 8) & 0xFF) / 255,
                        blue: CGFloat(light & 0xFF) / 255, alpha: 1)
        return Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : l
        })
    }

    /// The page itself. Grey on the light theme so white tiles and tables
    /// stand off it; the plain window colour on the dark theme.
    static let page    = dynamic(light: 0xE3E4E7, dark: .windowBackgroundColor)
    /// Tiles and table bodies.
    static let surface = dynamic(light: 0xFAFAFB, dark: NSColor.white.withAlphaComponent(0.045))
    /// Raised strip behind table headers, over `surface`.
    static let raised = overlay(light: 0.045, dark: 0.055)
    /// Every other table row.
    static let zebra  = overlay(light: 0.028, dark: 0.025)
    /// Frames and dividers.
    static let line   = overlay(light: 0.14, dark: 0.12)

    /// True-bold figures. SF has a real bold face, so this never reads as
    /// the thin synthetic bold Daftar was designed to avoid.
    static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    static let label = Font.system(size: 10.5, weight: .semibold)
}

extension Color {
    /// A tone laid over the surface at `alpha`, strengthened on the light
    /// theme (see `Daftar.lightBoost`).
    func tint(_ alpha: Double, _ scheme: ColorScheme) -> Color {
        opacity(scheme == .light ? min(alpha * Daftar.lightBoost, 1) : alpha)
    }
}

// MARK: - Pieces

/// Tinted square holding a symbol — the header's icon tile and the stat
/// tile's chip are the same shape at two sizes.
struct DaftarIconTile: View {
    let symbol: String
    let tone: Color
    var size: CGFloat = 44
    var radius: CGFloat = 13
    var alpha = Daftar.tileAlpha
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tone.tint(alpha, scheme))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tone)
                    .contentTransition(.symbolEffect(.replace))
            }
    }
}

/// Icon tile, title and muted subtitle; `trailing` — usually a
/// `DaftarPill` — on the right.
struct DaftarHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle = ""
    var tone = Daftar.accent.color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            DaftarIconTile(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension DaftarHeader where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String = "", tone: Color = Daftar.accent.color) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, tone: tone) { EmptyView() }
    }
}

/// The header's one headline figure.
struct DaftarPill: View {
    let label: String
    let value: String
    var unit = ""
    let tone: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Daftar.figure(20))
                    .foregroundStyle(tone)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(tone)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tone.tint(Daftar.pillAlpha, scheme))
                .strokeBorder(tone.tint(Daftar.borderAlpha, scheme), lineWidth: 1)
        )
    }
}

/// One figure in a stat row: icon chip, muted label, coloured figure and
/// a muted detail line underneath.
struct DaftarStat: View {
    let label: String
    let value: String
    let symbol: String
    let tone: Color
    /// Not optional: a tile without it is a line shorter than its
    /// neighbours, and the row stops lining up.
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DaftarIconTile(symbol: symbol, tone: tone, size: 30, radius: 9,
                           alpha: Daftar.chipAlpha)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Daftar.figure(16))
                    .foregroundStyle(tone)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Daftar.surface)
                .strokeBorder(Daftar.line, lineWidth: 1)
        )
        .animation(.smooth(duration: 0.3), value: value)
    }
}

/// A rounded pill naming a kind: icon and label in its tone.
struct DaftarBadge: View {
    let label: String
    var symbol: String? = nil
    let tone: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.tint(Daftar.chipAlpha, scheme)))
    }
}

/// A tinted hint: orange when something needs attention, never a solid
/// band. Optional trailing control (e.g. an Update button).
struct DaftarHint<Trailing: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tone = Daftar.warning.color
    var code: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DaftarIconTile(symbol: symbol, tone: tone, size: 30, radius: 9,
                           alpha: Daftar.chipAlpha)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Daftar.raised))
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Daftar.surface)
                .fill(tone.tint(Daftar.pillAlpha * 0.8, scheme))
                .strokeBorder(tone.tint(Daftar.borderAlpha, scheme), lineWidth: 1)
        )
    }
}

extension DaftarHint where Trailing == EmptyView {
    init(symbol: String, title: String, message: String,
         tone: Color = Daftar.warning.color, code: String? = nil) {
        self.init(symbol: symbol, title: title, message: message, tone: tone, code: code) { EmptyView() }
    }
}

// MARK: - Tables

/// The muted header strip at the top of a table frame.
struct DaftarTableHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(Daftar.label)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Daftar.raised)
            DaftarDivider()
        }
    }
}

extension DaftarTableHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

struct DaftarDivider: View {
    var body: some View {
        Rectangle().fill(Daftar.line).frame(height: 1)
    }
}

extension View {
    /// Rounded hairline frame around a table.
    func daftarFrame(radius: CGFloat = 12) -> some View {
        background(Daftar.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Daftar.line, lineWidth: 1)
            )
    }

    /// Row padding plus the zebra stripe for row `index`.
    func daftarRow(_ index: Int) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index.isMultiple(of: 2) ? Color.clear : Daftar.zebra)
    }

    /// Hero surface: a gradient tint of `tone` with a border in it.
    func daftarCard(_ tone: Color, radius: CGFloat = 16) -> some View {
        modifier(DaftarCard(tone: tone, radius: radius))
    }
}

struct DaftarCard: ViewModifier {
    let tone: Color
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Daftar.surface)
                .fill(LinearGradient(colors: [tone.tint(0.17, scheme), tone.tint(0.04, scheme)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .strokeBorder(tone.tint(0.32, scheme), lineWidth: 1)
        )
    }
}

/// A framed table of fixed rows — settings, tunnel facts. Each child of
/// `content` becomes one row with zebra striping and hairlines between.
/// (Long lists — Activity, History — build their rows lazily instead.)
struct DaftarTable<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                DaftarTableHeader(title: title)
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { DaftarDivider() }
                        row.daftarRow(index)
                    }
                }
            }
            .daftarFrame()

            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Muted label on the left, value on the right.
struct DaftarDetail: View {
    let label: String
    let value: String
    var mono = false
    var tone: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}

/// Standard page scaffolding: header on top, content below, on the plain
/// window surface.
struct DaftarPage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Daftar.page)
    }
}

/// The app icon's hazard stripes: amber bands on dark brown, leaning 20°
/// like the icon's. Drawn rather than bitmapped so it stays crisp at the
/// 18-point height of the menu bar.
struct HazardStripes: View {
    var band: CGFloat = 5
    var gap: CGFloat = 5.5
    var lean: Angle = .degrees(20)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Daftar.hazardDark.fixed(dark: true)))
            let amber = Daftar.hazardAmber.fixed(dark: true)
            let slant = size.height * CGFloat(tan(lean.radians))
            let period = band + gap
            var x = -slant - period
            while x < size.width + period {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x + slant, y: 0))
                stripe.addLine(to: CGPoint(x: x + slant + band, y: 0))
                stripe.addLine(to: CGPoint(x: x + band, y: size.height))
                stripe.addLine(to: CGPoint(x: x, y: size.height))
                stripe.closeSubpath()
                context.fill(stripe, with: .color(amber))
                x += period
            }
        }
    }
}
