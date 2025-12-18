//
//  NotificationManager.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25
//


import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("Notification auth error: \(error)")
            } else {
                print("Notification permission granted: \(granted)")
            }
        }
    }
    
    func scheduleDailyWord(at hour: Int, minute: Int, word: Word?) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily_wotd"])
        guard let word else { return }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let content = makeContent(for: word)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "daily_wotd", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to schedule WotD: \(error)") }
        }
    }

    func sendWordImmediately(_ word: Word?) {
        guard let word else { return }
        let content = makeContent(for: word)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "daily_wotd_\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to fire WotD now: \(error)") }
        }
    }

    func dictionaryURL(for word: Word) -> URL? {
        let trimmed = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let disallowed = CharacterSet(charactersIn: "?#")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wiktionary.org/wiki/\(encoded)")
    }

    private func makeContent(for word: Word) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Word of the Day"
        content.body = "\(word.surface)【\(word.reading)】 \(word.meaning)"
        content.sound = .default
        if let url = dictionaryURL(for: word) {
            content.userInfo["dictionaryURL"] = url.absoluteString
        }
        return content
    }
}
