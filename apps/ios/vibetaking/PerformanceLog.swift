import Foundation
import OSLog

/// Launch and load timing that can be read back with `log show` or Instruments.
///
/// `log show --predicate 'subsystem == "cn.1pointech.vibetaking" AND category == "perf"'`
nonisolated enum PerformanceLog {
    static let subsystem = "cn.1pointech.vibetaking"
    static let logger = Logger(subsystem: subsystem, category: "perf")
    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    /// Kernel-recorded process start, so the numbers include dyld and static initializers.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let status = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard status == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static var millisecondsSinceProcessStart: Int {
        Int(Date().timeIntervalSince(processStart) * 1000)
    }

    /// Records a launch milestone relative to process start.
    static func mark(_ event: StaticString, detail: String = "") {
        let ms = millisecondsSinceProcessStart
        logger.notice("\(event, privacy: .public) +\(ms, privacy: .public)ms \(detail, privacy: .public)")
        signposter.emitEvent(event, "\(ms, privacy: .public)ms \(detail, privacy: .public)")
    }

    /// Measures a synchronous block as a signpost interval and logs its duration.
    static func measure<T>(_ name: StaticString, detail: String = "", _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            logger.notice("\(name, privacy: .public) took \(ms, format: .fixed(precision: 1), privacy: .public)ms \(detail, privacy: .public)")
        }
        return try body()
    }
}
