//
//  NotificationManager.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation
import UIKit
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
            title: String(localized: "Download Complete"),
            body: String(format: String(localized: "%@ is ready to use.", defaultValue: "%@ is ready to use."), modelName)
        )
    }

    func postDownloadBackgroundWarning(modelName: String) {
        postNotification(
            title: String(localized: "Download May Pause"),
            body: String(format: String(localized: "Please return to the app to continue downloading %@.", defaultValue: "Please return to the app to continue downloading %@."), modelName)
        )
    }

    func postDownloadFailed(modelName: String, errorMessage: String) {
        postNotification(
            title: "Model Download Failed",
            body: "\(modelName): \(errorMessage)"
        )
    }

    /// Every local notification this app schedules goes through here, so this
    /// is the one place that has to get "don't interrupt someone already
    /// looking at the app" right. `.active` is the obvious case; `.inactive`
    /// covers the app still being on screen but transiently not receiving
    /// events — Control Center, Notification Center, a system permission
    /// alert, a share sheet — where a banner would be just as out of place.
    /// Only `.background` means the user has actually left.
    private func postNotification(title: String, body: String) {
        guard UIApplication.shared.applicationState == .background else { return }

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
