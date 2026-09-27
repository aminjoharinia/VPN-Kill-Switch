import SwiftUI

/// Live tail of the daemon log. Newest first — when something has just
/// gone wrong, the relevant line should be the one already on screen.
struct ActivityView: View {
    @Environment(Controller.self) private var controller
    @State private var filter = ""

    private var lines: [String] {
        guard !filter.isEmpty else { return controller.logLines }
        return controller.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private static func tone(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FATAL") { return Daftar.danger.color }
        if line.contains("WARN") || line.contains("WAKE:") { return Daftar.warning.color }
        if line.contains("-> down") || line.contains("block applied") { return Daftar.warning.color }
        if line.contains("-> up") || line.contains("block cleared") { return Daftar.good.color }
        return Daftar.muted.color.opacity(0.5)
    }

    /// "2026-09-27 13:28:47 message" → ("13:28:47", "message"). The date
    /// is the same on nearly every line, so only the time earns a column.
    private static func split(_ line: String) -> (time: String, message: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].count == 8, parts[1].contains(":") else { return ("", line) }
        return (String(parts[1]), String(parts[2]))
    }

    var body: some View {
        DaftarPage {
            DaftarHeader(symbol: "list.bullet.rectangle",
                         title: "Activity",
                         subtitle: "The daemon's log, newest first") {
                DaftarPill(label: filter.isEmpty ? "Events" : "Matching",
                           value: "\(lines.count)", tone: Daftar.accent.color)
            }
        } content: {
            if controller.logLines.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Events appear here once the kill switch is running.")
                )
                .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DaftarTableHeader(title: "Events") {
                        Text("last \(controller.logLines.count) lines")
                            .font(Daftar.label)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let entry = Self.split(line)
                        if index > 0 { DaftarDivider() }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(Self.tone(for: line))
                                .frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(entry.time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(index.isMultiple(of: 2) ? Color.clear : Daftar.zebra)
                    }
                }
                .daftarFrame()
            }
        }
        .searchable(text: $filter, prompt: "Filter events")
    }
}
