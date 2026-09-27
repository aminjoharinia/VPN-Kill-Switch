import SwiftUI

struct Endpoint: Codable, Identifiable, Equatable {
    var ip: String
    var lastSeen: Date
    var hits: Int
    var pinned: Bool

    var id: String { ip }
}

/// Reads and writes the exception store directly.
///
/// The daemon leaves endpoints.json group-writable and watches it for
/// changes, so adding or pinning an address takes effect within a second
/// without an authorisation prompt for every edit.
enum ExceptionStore {
    static let path = "/usr/local/var/vpn_kill_switch/endpoints.json"

    static func load() -> [Endpoint] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Endpoint].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ endpoints: [Endpoint]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(endpoints) else { return false }
        // Written in place so the root:admin 0664 permissions survive; an
        // atomic write would replace the file and lose them.
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return true
        } catch { return false }
    }

    static func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, let n = Int(part), (0...255).contains(n) else { return false }
            return true
        }
    }
}

struct ExceptionsView: View {
    @Environment(Controller.self) private var controller
    @State private var newAddress = ""
    @State private var error: String?

    private var endpoints: [Endpoint] {
        controller.endpoints.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.hits > b.hits
        }
    }

    var body: some View {
        DaftarPage {
            DaftarHeader(symbol: "pin",
                         title: "Exceptions",
                         subtitle: "VPN servers allowed through the block so your VPN can reconnect") {
                DaftarPill(label: "Stored", value: "\(endpoints.count)",
                           tone: Daftar.accent.color)
            }
        } content: {
            DaftarHint(symbol: "pin.fill",
                       title: "Pin your VPN server if reconnecting has ever failed",
                       message: "These addresses stay reachable while traffic is blocked. Pinned addresses are never removed automatically; the rest are learned while the tunnel is up and forgotten after two weeks unseen.",
                       tone: Daftar.accent.color)
            addBar
            VStack(spacing: 0) {
                DaftarTableHeader(title: "Addresses") {
                    Text("\(endpoints.filter(\.pinned).count) pinned")
                        .font(Daftar.label)
                        .foregroundStyle(.secondary)
                }
                if endpoints.isEmpty {
                    Text("Nothing learned yet. Addresses appear here while the tunnel is up.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .daftarRow(0)
                } else {
                    ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        if index > 0 { DaftarDivider() }
                        ExceptionRow(endpoint: endpoint).daftarRow(index)
                    }
                }
            }
            .daftarFrame()
        }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Add an address, e.g. 185.143.233.238", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onSubmit(add)
                Button("Add & Pin", systemImage: "pin") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ExceptionStore.isValidIPv4(newAddress.trimmingCharacters(in: .whitespaces)))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Daftar.danger.color)
            }
        }
    }

    private func add() {
        let ip = newAddress.trimmingCharacters(in: .whitespaces)
        guard ExceptionStore.isValidIPv4(ip) else { error = "Not a valid IPv4 address."; return }
        error = controller.addException(ip) ? nil : "Could not write the exception list."
        if error == nil { newAddress = "" }
    }
}

struct ExceptionRow: View {
    @Environment(Controller.self) private var controller
    let endpoint: Endpoint

    private static let seen: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    private var tone: Color { endpoint.pinned ? Daftar.accent.color : Daftar.muted.color }

    var body: some View {
        HStack(spacing: 12) {
            DaftarIconTile(symbol: endpoint.pinned ? "pin.fill" : "arrow.up.forward",
                           tone: tone, size: 28, radius: 8, alpha: Daftar.chipAlpha)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(endpoint.ip)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    if endpoint.pinned {
                        DaftarBadge(label: "Pinned", tone: Daftar.accent.color)
                    }
                }
                Text("\(endpoint.hits) sighting\(endpoint.hits == 1 ? "" : "s") · last seen \(Self.seen.string(from: endpoint.lastSeen))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button {
                controller.setPinned(endpoint.ip, !endpoint.pinned)
            } label: {
                Image(systemName: endpoint.pinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(endpoint.pinned ? "Unpin — allow automatic cleanup" : "Pin — never remove automatically")

            Button(role: .destructive) {
                controller.removeException(endpoint.ip)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Daftar.danger.color)
            .help("Remove this exception")
        }
    }
}
