//
//  DownloadNetworkMonitor.swift
//  LocalAI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import Network

extension Notification.Name {
    static let downloadNetworkRestrictionDidChange = Notification.Name("downloadNetworkRestrictionDidChange")
}

final class DownloadNetworkMonitor: @unchecked Sendable {
    static let shared = DownloadNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LocalAI.DownloadNetworkMonitor")
    private let lock = NSLock()
    private var lastPath: NWPath?
    private var isRestricted = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.lastPath = path
            
            // Check restriction
            let restricted = path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
            let changed = self.isRestricted != restricted
            self.isRestricted = restricted
            self.lock.unlock()
            
            if changed {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .downloadNetworkRestrictionDidChange, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }

    var isCellularRestricted: Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let path = lastPath ?? monitor.currentPath
        return path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
    }
}
