//
//  MemoryProfiler.swift
//  LocalAI
//
//  Created by Antigravity on 18.03.2026.
//

import Foundation
import MachO

/// Utility to monitor and log memory usage (Resident Set Size).
enum MemoryProfiler {
    final class PeakTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPeak: UInt64

        init(initialValue: UInt64 = MemoryProfiler.currentResidentMemory) {
            storedPeak = initialValue
        }

        func sample() {
            let value = MemoryProfiler.currentResidentMemory
            lock.lock()
            storedPeak = max(storedPeak, value)
            lock.unlock()
        }

        var peak: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return storedPeak
        }
    }

    struct PeakSamplingSession: Sendable {
        let tracker: PeakTracker
        let task: Task<Void, Never>

        func stop() -> UInt64 {
            task.cancel()
            tracker.sample()
            return tracker.peak
        }
    }
    
    /// Returns the current resident memory in bytes.
    nonisolated static var currentResidentMemory: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    nonisolated static func startPeakSampling(
        interval: Duration = .milliseconds(40)
    ) -> PeakSamplingSession {
        let tracker = PeakTracker()
        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                tracker.sample()
                try? await Task.sleep(for: interval)
            }
        }
        return PeakSamplingSession(tracker: tracker, task: task)
    }
    
    /// Formats bytes into a human-readable string (e.g., "128.5 MB").
    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
    
    nonisolated static func log(_ tag: String, message: String? = nil) {
        PerformanceLogger.memory(tag, message: message)
    }
    
    /// Measures memory delta for an operation.
    nonisolated static func measure<T>(_ tag: String, operation: () async throws -> T) async rethrows -> T {
        let startMemory = currentResidentMemory
        log(tag, message: "START (Previous: \(formatBytes(startMemory)))")
        
        let result = try await operation()
        
        let endMemory = currentResidentMemory
        let delta = Int64(endMemory) - Int64(startMemory)
        let deltaPrefix = delta >= 0 ? "+" : ""
        log(tag, message: "END (Current: \(formatBytes(endMemory)), Delta: \(deltaPrefix)\(formatBytes(UInt64(abs(delta)))))")
        
        return result
    }

    /// Synchronous version of measure.
    nonisolated static func measureSync<T>(_ tag: String, operation: () throws -> T) rethrows -> T {
        let startMemory = currentResidentMemory
        log(tag, message: "START (Previous: \(formatBytes(startMemory)))")
        
        let result = try operation()
        
        let endMemory = currentResidentMemory
        let delta = Int64(endMemory) - Int64(startMemory)
        let deltaPrefix = delta >= 0 ? "+" : ""
        log(tag, message: "END (Current: \(formatBytes(endMemory)), Delta: \(deltaPrefix)\(formatBytes(UInt64(abs(delta)))))")
        
        return result
    }
}
