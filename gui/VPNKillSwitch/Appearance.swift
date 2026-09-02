import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark:  return "moon.fill"
        }
    }

    /// nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

struct AppearancePicker: View {
    @AppStorage("appearance") private var appearance = Appearance.auto

    /// Date-based build version, e.g. 26.08.23 — stamped by gui/build.sh.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(short)"
    }

    var body: some View {
        VStack(spacing: 6) {
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Label(option.label, systemImage: option.symbol)
                        .labelStyle(.iconOnly)
                        .help(option.label)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)

            Text(version)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .background(.bar)
    }
}
