//
//  NotificationManager.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    
    private let launchCountKey = "appLaunchCount"
    private(set) var launchCount: Int {
        get { UserDefaults.standard.integer(forKey: launchCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchCountKey) }
    }

    private init() {}
    
    func incrementLaunchCount() {
        launchCount += 1
    }

    @MainActor
    func requestAuthorizationIfNeeded() async -> Bool {
        // Only ask on the 2nd launch or later
        guard launchCount >= 2 else {
            return false
        }
        
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func postDownloadCompleted(modelName: String) {
        postNotification(
            title: "Download Complete",
            body: "\(modelName) is ready to use."
        )
    }

    func postDownloadBackgroundWarning(modelName: String) {
        postNotification(
            title: "Download May Pause",
            body: "Please return to the app to continue downloading \(modelName)."
        )
    }

    func postDownloadFailed(modelName: String, errorMessage: String) {
        postNotification(
            title: "Model Download Failed",
            body: "\(modelName): \(errorMessage)"
        )
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request)
    }
}
