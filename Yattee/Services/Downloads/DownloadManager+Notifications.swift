//
//  DownloadManager+Notifications.swift
//  Yattee
//
//  Local notifications for downloads that finish while the app is in the background.
//

import Foundation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if !os(tvOS)

extension DownloadManager {
    private var isAppInBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .active
        #else
        !NSApp.isActive
        #endif
    }

    /// Posts a notification when a download completes or fails while the app isn't
    /// frontmost. Does nothing unless the user has already granted notification permission.
    func notifyDownloadFinishedInBackground(title: String, failed: Bool) {
        guard isAppInBackground else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = failed
                ? String(localized: "toast.download.failed.title")
                : String(localized: "toast.download.completed.title")
            content.body = title
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

#endif
