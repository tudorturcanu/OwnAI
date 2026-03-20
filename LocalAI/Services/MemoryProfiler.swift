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
    
    /// Returns the current resident memory in bytes.
    static var currentResidentMemory: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
    
    /// Formats bytes into a human-readable string (e.g., "128.5 MB").
    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
    
    /// Logs the current memory usage with a tag.
    static func log(_ tag: String, message: String? = nil) {
        let memory = currentResidentMemory
        let formatted = formatBytes(memory)
        var logMessage = "[MemoryProfiler] [\(tag)] Memory: \(formatted)"
        if let message = message {
            logMessage += " - \(message)"
        }
        print(logMessage)
    }
    
    /// Measures memory delta for an operation.
    static func measure<T>(_ tag: String, operation: () async throws -> T) async rethrows -> T {
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
    static func measureSync<T>(_ tag: String, operation: () throws -> T) rethrows -> T {
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
