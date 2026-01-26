//
//  KyoukuApp.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25
//

import SwiftUI
import UserNotifications

@main
struct KyoukuApp: App {
    @StateObject private var readingOverrides: ReadingOverridesStore
    @StateObject private var tokenBoundaries: TokenBoundariesStore
    @StateObject private var notes: NotesStore
    @StateObject private var store: WordsStore
    @StateObject private var router: AppRouter
    @StateObject private var themes: ThemeDiscoveryStore
    @StateObject private var notificationDeepLinkHandler: NotificationDeepLinkHandlerHolder

    init() {
        let overrides = ReadingOverridesStore()
        _readingOverrides = StateObject(wrappedValue: overrides)
        _tokenBoundaries = StateObject(wrappedValue: TokenBoundariesStore())
        _notes = StateObject(wrappedValue: NotesStore(readingOverrides: overrides))
        _store = StateObject(wrappedValue: WordsStore())
        let router = AppRouter()
        _router = StateObject(wrappedValue: router)
        _themes = StateObject(wrappedValue: ThemeDiscoveryStore())

        // Retain a UNUserNotificationCenter delegate that can deep-link into the app.
        _notificationDeepLinkHandler = StateObject(wrappedValue: NotificationDeepLinkHandlerHolder(router: router))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notes)
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(readingOverrides)
                .environmentObject(tokenBoundaries)
                .environmentObject(themes)
                .onOpenURL { url in
                    // Expect kyouku://inbox to route to Paste tab; PasteView will ingest on appear/activation
                    if url.scheme == "kyouku" && url.host == "inbox" {
                        router.selectedTab = .paste
                    }
                }
                .task {
                    // Ensure the handler is retained for the app lifetime.
                    _ = notificationDeepLinkHandler
                    await ReadingOverridePolicy.shared.warmUp()
                    await LegacyNotificationCleanup.runIfNeeded()

                    let defaults = UserDefaults.standard
                    let enabled = defaults.bool(forKey: WordOfTheDayScheduler.enabledKey)
                    let hour = defaults.object(forKey: WordOfTheDayScheduler.hourKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.hourKey) : 9
                    let minute = defaults.object(forKey: WordOfTheDayScheduler.minuteKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.minuteKey) : 0
                    let words = store.allWords()
                    await WordOfTheDayScheduler.refreshScheduleIfEnabled(words: words, hour: hour, minute: minute, enabled: enabled)
                }
        }
    }
}

@MainActor
final class NotificationDeepLinkHandlerHolder: ObservableObject {
    let handler: NotificationDeepLinkHandler

    init(router: AppRouter) {
        self.handler = NotificationDeepLinkHandler(router: router)
    }
}
