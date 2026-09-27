import Foundation
import Security

/// Runs one shell command as root behind a standard macOS administrator
/// prompt, entirely off the main thread.
///
/// The prompt is raised by `AuthorizationCopyRights`, so macOS shows it
/// with this app's name and icon and the `prompt` text. The command then
/// runs through `AuthorizationExecuteWithPrivileges` — the same mechanism
/// `do shell script … with administrator privileges` uses underneath.
///
/// That function has been deprecated since macOS 10.7 and Swift does not
/// import it, so it is looked up at run time. It still ships (verified on
/// macOS 26.6.2). If a future release removes it, `run` reports
/// `.unavailable` and the caller falls back to AppleScript.
enum PrivilegedRunner {
    enum Result: Sendable {
        case done
        case cancelled
        case failed(String)
        case unavailable
    }

    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let execute: ExecuteWithPrivileges? = {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(security, "AuthorizationExecuteWithPrivileges")
        else { return nil }
        return unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
    }()

    /// The command's exit status is not reported by the API, so the shell
    /// prints it after the output, behind this marker.
    private static let exitMarker = "__VPNKS_EXIT__:"

    static func run(command: String, prompt: String) -> Result {
        guard let execute else { return .unavailable }

        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization
        else { return .failed("Could not start an authorisation session.") }
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        // Ask for the admin right up front, with our own explanation. This
        // is the call that shows the password dialog.
        let status = requestAdminRight(authorization, prompt: prompt)
        if status == errAuthorizationCanceled { return .cancelled }
        guard status == errAuthorizationSuccess else {
            return .failed("Authorisation failed (error \(status)).")
        }

        // /bin/sh -p -c '<command> 2>&1; echo MARKER$?'
        //
        // -p matters: the command starts with root's effective id but the
        // user's real id, and /bin/sh (bash on macOS) drops root in exactly
        // that case unless told not to. Without it every command failed
        // with "needs root".
        let script = "\(command) 2>&1; echo \"\(exitMarker)$?\""
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("-p"), strdup("-c"), strdup(script), nil]
        defer { arguments.forEach { free($0) } }

        var pipe: UnsafeMutablePointer<FILE>?
        let launched = arguments.withUnsafeBufferPointer { buffer in
            execute(authorization, "/bin/sh", [], buffer.baseAddress!, &pipe)
        }
        guard launched == errAuthorizationSuccess, let pipe else {
            // The tool could not be started at all — treat as "this API no
            // longer works here" so the AppleScript path gets a chance.
            return launched == errAuthorizationToolExecuteFailure
                ? .unavailable
                : .failed("Could not run the command (error \(launched)).")
        }

        let data = FileHandle(fileDescriptor: fileno(pipe), closeOnDealloc: false)
            .readDataToEndOfFile()
        fclose(pipe)
        reapChildren()

        var output = String(decoding: data, as: UTF8.self)
        guard let marker = output.range(of: exitMarker, options: .backwards) else {
            return .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let code = Int(output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        output = String(output[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 ? .done : .failed(output)
    }

    private static func requestAdminRight(_ authorization: AuthorizationRef, prompt: String) -> OSStatus {
        "system.privilege.admin".withCString { rightName in
            var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { rightPointer in
                var rights = AuthorizationRights(count: 1, items: rightPointer)
                return "prompt".withCString { promptKey in
                    prompt.withCString { promptText in
                        var promptItem = AuthorizationItem(
                            name: promptKey,
                            valueLength: strlen(promptText),
                            value: UnsafeMutableRawPointer(mutating: promptText),
                            flags: 0)
                        return withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(
                                authorization, &rights, &environment,
                                [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
    }

    /// The API forks a helper (security_authtrampoline) as our child and
    /// never waits for it; reap it so it does not linger as a zombie. This
    /// app starts no other child processes.
    private static func reapChildren() {
        for _ in 0..<40 {
            var status: Int32 = 0
            let pid = waitpid(-1, &status, WNOHANG)
            if pid > 0 { continue }        // reaped one; there may be more
            if pid < 0 { return }          // ECHILD: none left
            usleep(25_000)                 // still exiting
        }
    }
}
