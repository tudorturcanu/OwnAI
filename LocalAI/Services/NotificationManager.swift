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

    private init() {}

    @MainActor
    func requestAuthorizationIfNeeded() async -> Bool {
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

    func postDownloadStarted(modelName: String) {
        postNotification(
            title: "Model Download Started",
            body: "Downloading \(modelName)."
        )
    }

    func postDownloadProgress(modelName: String, percent: Int) {
        postNotification(
            title: "Model Download \(percent)%",
            body: "\(modelName) is downloading."
        )
    }

    func postDownloadCompleted(modelName: String) {
        postNotification(
            title: "Model Download Complete",
            body: "\(modelName) is ready to use."
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
