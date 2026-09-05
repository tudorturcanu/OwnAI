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

    /// Whether the *current* restriction is actually cellular, as opposed to
    /// Wi-Fi that's expensive (a Personal Hotspot) or constrained (Low Data
    /// Mode, which a user can turn on for an ordinary Wi-Fi network). Lets a
    /// caller avoid telling someone already on Wi-Fi to "connect to Wi-Fi".
    var isActuallyCellular: Bool {
        lock.lock()
        defer { lock.unlock() }

        let path = lastPath ?? monitor.currentPath
        return path.usesInterfaceType(.cellular)
    }
}
