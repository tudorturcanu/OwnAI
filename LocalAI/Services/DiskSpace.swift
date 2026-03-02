//
//  DiskSpace.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation

enum DiskSpace {
    static func availableGB() -> Double {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return Double(bytes) / 1_073_741_824.0
        }

        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            return Double(bytes) / 1_073_741_824.0
        }

        return 0
    }
}
