//
//  DownloadNetworkMonitor.swift
//  LocalAI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import Network

final class DownloadNetworkMonitor {
    static let shared = DownloadNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LocalAI.DownloadNetworkMonitor")

    private init() {
        monitor.start(queue: queue)
    }

    var isCellularRestricted: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && (path.isExpensive || path.isConstrained)
    }
}
