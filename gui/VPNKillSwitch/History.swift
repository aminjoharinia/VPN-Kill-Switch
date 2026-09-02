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

struct TrafficPair: View {
    let down: UInt64
    let up: UInt64
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            Label(Format.bytes(down), systemImage: "arrow.down")
                .foregroundStyle(.blue)
            Label(Format.bytes(up), systemImage: "arrow.up")
                .foregroundStyle(.purple)
        }
        .font(.system(compact ? .caption : .body, design: .rounded))
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
    }
}

struct HistoryView: View {
    @Environment(Controller.self) private var controller

    private var sessions: [Session] { controller.sessions }

    private var totalDown: UInt64 { sessions.reduce(0) { $0 &+ $1.bytesIn } }
    private var totalUp: UInt64 { sessions.reduce(0) { $0 &+ $1.bytesOut } }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("A session is recorded each time the tunnel comes up while the kill switch is running.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        SummaryCard(count: sessions.count, down: totalDown, up: totalUp)
                        ForEach(sessions) { SessionRow(session: $0) }
                    }
                    .padding(18)
                }
            }
        }
        .background(.background.secondary)
    }
}

struct SummaryCard: View {
    let count: Int
    let down: UInt64
    let up: UInt64

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(count) session\(count == 1 ? "" : "s")")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("recorded total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TrafficPair(down: down, up: up)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.isActive ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(session.isActive ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Format.started.string(from: session.startedAt))
                        .fontWeight(.medium)
                    if session.isActive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.green.opacity(0.22)))
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                TrafficPair(down: session.bytesIn, up: session.bytesOut, compact: true)
                Text(Format.duration(session.duration))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(session.isActive ? .green.opacity(0.10) : .clear),
                     in: .rect(cornerRadius: 12))
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
