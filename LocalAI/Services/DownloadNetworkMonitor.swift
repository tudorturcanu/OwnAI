//
//  DownloadNetworkMonitor.swift
//  LocalAI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import Network

final class DownloadNetworkMonitor: @unchecked Sendable {
    static let shared = DownloadNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LocalAI.DownloadNetworkMonitor")
    private let lock = NSLock()
    private var lastPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.lastPath = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isCellularRestricted: Bool {
        lock.lock()
        let path = lastPath ?? monitor.currentPath
        lock.unlock()
        return path.status == .satisfied && (path.isExpensive || path.isConstrained)
    }
}
