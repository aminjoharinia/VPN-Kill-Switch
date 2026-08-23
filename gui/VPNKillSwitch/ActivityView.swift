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

    private func tint(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FATAL") { return .red }
        if line.contains("WARN") || line.contains("WAKE:") { return .orange }
        if line.contains("-> down") || line.contains("block applied") { return .orange }
        if line.contains("-> up") || line.contains("block cleared") { return .green }
        return .secondary
    }

    var body: some View {
        Group {
            if controller.logLines.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Events appear here once the kill switch is running.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(tint(for: line))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 14)
                            .background(index.isMultiple(of: 2)
                                        ? Color.clear : Color.primary.opacity(0.03))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter events")
        .background(.background.secondary)
    }
}
