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
        ScrollView {
            VStack(spacing: 14) {
                explainer
                addBar
                if endpoints.isEmpty {
                    Text("Nothing learned yet. Addresses appear here while the tunnel is up.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(endpoints) { endpoint in
                        ExceptionRow(endpoint: endpoint)
                    }
                }
            }
            .padding(18)
        }
        .background(.background.secondary)
    }

    private var explainer: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("These addresses stay reachable while traffic is blocked, so your VPN client can reconnect.")
                    .foregroundStyle(.secondary)
                Label("Pinned addresses are never removed automatically. Pin your VPN server if reconnecting has ever failed.",
                      systemImage: "pin.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("Add an address, e.g. 185.143.233.238", text: $newAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add & Pin", systemImage: "pin") { add() }
                .buttonStyle(.glassProminent)
                .disabled(!ExceptionStore.isValidIPv4(newAddress.trimmingCharacters(in: .whitespaces)))
        }
        .overlay(alignment: .bottomLeading) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).offset(y: 18)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: endpoint.pinned ? "pin.fill" : "arrow.up.forward.circle")
                .foregroundStyle(endpoint.pinned ? .orange : .blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.ip)
                    .font(.system(.body, design: .monospaced))
                Text("\(endpoint.hits) sighting\(endpoint.hits == 1 ? "" : "s") · last seen \(Self.seen.string(from: endpoint.lastSeen))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button {
                controller.setPinned(endpoint.ip, !endpoint.pinned)
            } label: {
                Label(endpoint.pinned ? "Pinned" : "Pin",
                      systemImage: endpoint.pinned ? "pin.fill" : "pin")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.glass)
            .help(endpoint.pinned ? "Stop protecting this entry from cleanup" : "Never remove this entry automatically")

            Button(role: .destructive) {
                controller.removeException(endpoint.ip)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.glass)
            .help("Remove this exception")
        }
        .padding(12)
        .glassEffect(.regular.tint(endpoint.pinned ? .orange.opacity(0.10) : .clear),
                     in: .rect(cornerRadius: 12))
    }
}
