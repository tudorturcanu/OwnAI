import Foundation
import OSLog

/// Low-overhead instrumentation for user-visible latency.
///
/// Timed operations appear both in Console (category `Performance`) and in the
/// Points of Interest track in Instruments. Metadata must describe shape and
/// state only—never prompts, extracted text, or other user content.
enum PerformanceLogger {
    nonisolated private static let sessionID = UUID()

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let label: String
        fileprivate let id: OSSignpostID
        fileprivate let startedAt: CFTimeInterval
        let metadata: String
    }

    // Keep this a literal: Bundle.main is main-actor isolated under strict
    // concurrency, while diagnostics are intentionally callable off-actor.
    nonisolated private static let subsystem = "alice.turcanu.LocalAI"
    nonisolated private static let performanceLog = OSLog(subsystem: subsystem, category: "Performance")
    nonisolated private static let logger = Logger(subsystem: subsystem, category: "Performance")
    nonisolated private static let diagnosticsLogger = Logger(subsystem: subsystem, category: "Diagnostics")

    @discardableResult
    nonisolated static func begin(
        _ name: StaticString,
        label: String,
        metadata: String = ""
    ) -> Interval {
        let id = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: name,
            signpostID: id,
            "%{public}@",
            metadata as NSString
        )
        logger.notice("BEGIN \(label, privacy: .public) \(metadata, privacy: .public)")
        return Interval(
            name: name,
            label: label,
            id: id,
            startedAt: ProcessInfo.processInfo.systemUptime,
            metadata: metadata
        )
    }

    nonisolated static func end(
        _ interval: Interval,
        status: String = "success",
        metadata: String = ""
    ) {
        let durationMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - interval.startedAt) * 1_000)
        let durationText = String(format: "%.1f", durationMilliseconds)
        let details = [interval.metadata, metadata]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        os_signpost(
            .end,
            log: performanceLog,
            name: interval.name,
            signpostID: interval.id,
            "status=%{public}@ duration_ms=%{public}@ %{public}@",
            status as NSString,
            durationText as NSString,
            details as NSString
        )
        logger.notice(
            "END \(interval.label, privacy: .public) duration_ms=\(durationText, privacy: .public) status=\(status, privacy: .public) \(details, privacy: .public)"
        )
        persist(
            PerformanceSample(
                sessionID: sessionID,
                name: interval.label,
                kind: .interval,
                durationMilliseconds: durationMilliseconds,
                status: status,
                metadata: details
            )
        )
    }

    nonisolated static func event(
        _ name: StaticString,
        label: String,
        metadata: String = ""
    ) {
        os_signpost(
            .event,
            log: performanceLog,
            name: name,
            "%{public}@",
            metadata as NSString
        )
        logger.notice("EVENT \(label, privacy: .public) \(metadata, privacy: .public)")
        persist(
            PerformanceSample(
                sessionID: sessionID,
                name: label,
                kind: .event,
                durationMilliseconds: numericValue(named: "latency_ms", in: metadata),
                metadata: metadata
            )
        )
    }

    nonisolated static func elapsedMilliseconds(since interval: Interval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - interval.startedAt) * 1_000)
    }

    /// Detailed sequencing logs. Values remain private in Console unless the
    /// developer explicitly enables private-data display.
    nonisolated static func diagnostic(_ message: String) {
        diagnosticsLogger.debug("\(message, privacy: .private(mask: .hash))")
    }

    /// Diagnostics that are explicitly scrubbed of prompts, filenames, and
    /// other user content before reaching this API.
    nonisolated static func safeDiagnostic(_ message: String) {
        diagnosticsLogger.error("\(message, privacy: .public)")
        #if DEBUG
        // os.Logger output does not reliably surface in Xcode's console (it
        // shows only in Console.app). Write to BOTH stderr (NSLog) and stdout
        // (print) so these diagnostics appear in the Xcode debug area no matter
        // which output-filter mode the console is set to.
        NSLog("[Diagnostics] %@", message)
        print("[Diagnostics] \(message)")
        #endif
    }

    nonisolated static func memory(_ tag: String, message: String?) {
        let resident = MemoryProfiler.formatBytes(MemoryProfiler.currentResidentMemory)
        logger.debug(
            "MEMORY \(tag, privacy: .public) resident=\(resident, privacy: .public) \(message ?? "", privacy: .private(mask: .hash))"
        )
        persist(
            PerformanceSample(
                sessionID: sessionID,
                name: tag,
                kind: .memory,
                residentMemoryBytes: MemoryProfiler.currentResidentMemory
            )
        )
    }

    nonisolated private static func numericValue(named key: String, in metadata: String) -> Double? {
        metadata
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("\(key)=") })
            .flatMap { Double($0.dropFirst(key.count + 1)) }
    }

    nonisolated private static func persist(_ sample: PerformanceSample) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PerformanceMetricsStore.collectionEnabledKey) != nil,
           !defaults.bool(forKey: PerformanceMetricsStore.collectionEnabledKey) {
            return
        }
        Task(priority: .utility) {
            await PerformanceMetricsStore.shared.record(sample)
        }
    }
}
