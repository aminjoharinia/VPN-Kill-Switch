import SwiftUI

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var interfaceName: String
    var vpnAppName: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var blockCount: Int

    var isActive: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var total: UInt64 { bytesIn &+ bytesOut }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60   { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    static let started: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()
}

/// Download and upload side by side. Direction is the meaning here, so
/// each has its own tone — blue down, violet up — kept identical
/// everywhere a byte count appears.
struct TrafficPair: View {
    let down: UInt64
    let up: UInt64
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            Label(Format.bytes(down), systemImage: "arrow.down")
                .foregroundStyle(Daftar.armed.color)
            Label(Format.bytes(up), systemImage: "arrow.up")
                .foregroundStyle(Daftar.accent.color)
        }
        .font(compact ? .system(size: 11.5, weight: .semibold, design: .rounded)
                      : Daftar.figure(14))
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
    }
}

struct HistoryView: View {
    @Environment(Controller.self) private var controller

    private var sessions: [Session] { controller.sessions }

    private var totalDown: UInt64 { sessions.reduce(0) { $0 &+ $1.bytesIn } }
    private var totalUp: UInt64 { sessions.reduce(0) { $0 &+ $1.bytesOut } }
    private var totalBlocks: Int { sessions.reduce(0) { $0 + $1.blockCount } }
    private var totalTime: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }

    var body: some View {
        DaftarPage {
            DaftarHeader(symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                         title: "History",
                         subtitle: "One session each time the tunnel comes up while the kill switch runs") {
                DaftarPill(label: "Sessions", value: "\(sessions.count)", tone: Daftar.accent.color)
            }
        } content: {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("A session is recorded each time the tunnel comes up while the kill switch is running.")
                )
                .padding(.top, 40)
            } else {
                HStack(spacing: 10) {
                    DaftarStat(label: "Downloaded", value: Format.bytes(totalDown),
                               symbol: "arrow.down", tone: Daftar.armed.color,
                               detail: "all sessions")
                    DaftarStat(label: "Uploaded", value: Format.bytes(totalUp),
                               symbol: "arrow.up", tone: Daftar.accent.color,
                               detail: "all sessions")
                    DaftarStat(label: "Connected", value: Format.duration(totalTime),
                               symbol: "timer", tone: Daftar.good.color,
                               detail: "total tunnel time")
                    DaftarStat(label: "Blocks", value: "\(totalBlocks)",
                               symbol: "hand.raised", tone: Daftar.warning.color,
                               detail: "times traffic was cut")
                }
                .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: 0) {
                    DaftarTableHeader(title: "Sessions") {
                        Text("newest first")
                            .font(Daftar.label)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { DaftarDivider() }
                        SessionRow(session: session).daftarRow(index)
                    }
                }
                .daftarFrame()
            }
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            DaftarIconTile(symbol: session.isActive ? "dot.radiowaves.left.and.right" : "checkmark",
                           tone: session.isActive ? Daftar.good.color : Daftar.muted.color,
                           size: 28, radius: 8, alpha: Daftar.chipAlpha)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(Format.started.string(from: session.startedAt))
                        .font(.system(size: 13, weight: .medium))
                    if session.isActive {
                        DaftarBadge(label: "LIVE", tone: Daftar.good.color)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                TrafficPair(down: session.bytesIn, up: session.bytesOut, compact: true)
                Text(Format.duration(session.duration))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}
private extension SessionRow {
    var detail: String {
        var parts: [String] = []
        let name = session.vpnAppName.cleanedVPNName
        if !name.isEmpty { parts.append(name) }
        if !session.interfaceName.isEmpty { parts.append(session.interfaceName) }
        if session.blockCount > 0 {
            parts.append("\(session.blockCount) block\(session.blockCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}
