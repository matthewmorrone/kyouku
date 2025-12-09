//
//  NotificationManager.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
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
        
        guard let word = word else {
            return
        }
        
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        
        let content = UNMutableNotificationContent()
        content.title = "Word of the Day"
        content.body = "\(word.surface)【\(word.reading)】 \(word.meaning)"
        content.sound = .default
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "daily_wotd",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule WotD: \(error)")
            }
        }
    }
}