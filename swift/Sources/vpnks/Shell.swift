import Foundation

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        // stdout and stderr are kept apart on purpose. Merging them meant a
        // pfctl warning on stderr could land ahead of the real output, so
        // parsing "Status: Enabled" failed and the daemon believed pf was
        // off — re-applying the ruleset every single second, forever.
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
