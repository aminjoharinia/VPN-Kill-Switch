import Foundation
import Network
import IOKit
import IOKit.pwr_mgt

/// Instant notification of network path changes.
///
/// This replaces `route -n monitor` piped through a FIFO. That pipeline
/// was the single worst part of the shell design: a blocking FIFO open
/// that stalled the poll loop, a firehose of route churn on proxy-type
/// VPNs, and a fork per check. NWPathMonitor coalesces changes in the
/// kernel and hands us one callback.
final class PathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vpnks.path")
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in self?.onChange?() }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}

/// Real sleep/wake notifications from IOKit.
///
/// The shell version could only infer suspension after the fact, by
/// noticing that its own loop had not run for a while. Here the kernel
/// tells us, so the block can be re-asserted the instant the machine
/// comes back — before the VPN client has finished reconnecting.
final class PowerWatcher {
    // IOKit publishes these as macros built from iokit_common_msg(), which
    // Swift cannot import ("structure not supported"). Values verified
    // against IOMessage.h by compiling the macros in C.
    private static let kCanSystemSleep: UInt32      = 0xE000_0270
    private static let kSystemWillSleep: UInt32     = 0xE000_0280
    private static let kSystemHasPoweredOn: UInt32  = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    var onWake: (() -> Void)?
    var onSleep: (() -> Void)?

    static var shared: PowerWatcher?

    func start() {
        PowerWatcher.shared = self
        let callback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
            guard let watcher = PowerWatcher.shared else { return }
            switch messageType {
            case PowerWatcher.kCanSystemSleep, PowerWatcher.kSystemWillSleep:
                watcher.onSleep?()
                // Must acknowledge, or we delay system sleep by 30s.
                IOAllowPowerChange(watcher.rootPort,
                                   Int(bitPattern: messageArgument))
            case PowerWatcher.kSystemHasPoweredOn:
                watcher.onWake?()
            default:
                break
            }
        }
        rootPort = IORegisterForSystemPower(nil, &notifyPort, callback, &notifier)
        guard rootPort != 0, let port = notifyPort else {
            log("WARN: could not register for system power notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
    }
}
