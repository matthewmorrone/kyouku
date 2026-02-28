//
//  KyoukuApp.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25
//

import SwiftUI
import UserNotifications
import Combine

@main
struct KyoukuApp: App {
    @StateObject private var readingOverrides: ReadingOverridesStore
    @StateObject private var tokenBoundaries: TokenBoundariesStore
    @StateObject private var notes: NotesStore
    @StateObject private var store: WordsStore
    @StateObject private var router: AppRouter
    @StateObject private var notificationDeepLinkHandler: NotificationDeepLinkHandlerHolder

    init() {
        _ = CustomLogger.perfStart()

        _ = CustomLogger.perfStart()
        let overrides = ReadingOverridesStore()
        // CustomLogger.shared.perf("AppInit ReadingOverridesStore", elapsedMS: CustomLogger.perfElapsedMS(since: overridesStart))

        _readingOverrides = StateObject(wrappedValue: overrides)

        _ = CustomLogger.perfStart()
        _tokenBoundaries = StateObject(wrappedValue: TokenBoundariesStore())
        // CustomLogger.shared.perf("AppInit TokenBoundariesStore", elapsedMS: CustomLogger.perfElapsedMS(since: start))

        _ = CustomLogger.perfStart()
        _notes = StateObject(wrappedValue: NotesStore(readingOverrides: overrides))
        // CustomLogger.shared.perf("AppInit NotesStore", elapsedMS: CustomLogger.perfElapsedMS(since: start))

        _ = CustomLogger.perfStart()
        _store = StateObject(wrappedValue: WordsStore())
        // CustomLogger.shared.perf("AppInit WordsStore", elapsedMS: CustomLogger.perfElapsedMS(since: start))

        _ = CustomLogger.perfStart()
        let router = AppRouter()
        // CustomLogger.shared.perf("AppInit AppRouter", elapsedMS: CustomLogger.perfElapsedMS(since: start))
        _router = StateObject(wrappedValue: router)

        // Retain a UNUserNotificationCenter delegate that can deep-link into the app.
        _ = CustomLogger.perfStart()
        _notificationDeepLinkHandler = StateObject(wrappedValue: NotificationDeepLinkHandlerHolder(router: router))
        // CustomLogger.shared.perf("AppInit NotificationDeepLinkHandler", elapsedMS: CustomLogger.perfElapsedMS(since: deepLinkStart))

        // CustomLogger.shared.perf("AppInit Total", elapsedMS: CustomLogger.perfElapsedMS(since: appInitStart))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notes)
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(readingOverrides)
                .environmentObject(tokenBoundaries)
                .onOpenURL { url in
                    // Expect kyouku://inbox to route to Paste tab; PasteView will ingest on appear/activation
                    if url.scheme == "kyouku" && url.host == "inbox" {
                        router.selectedTab = .paste
                    }
                }
                .task {
                    _ = CustomLogger.perfStart()

                    // Ensure the handler is retained for the app lifetime.
                    _ = CustomLogger.perfStart()
                    _ = notificationDeepLinkHandler
                    // CustomLogger.shared.perf("AppLaunch RetainDeepLinkHandler", elapsedMS: CustomLogger.perfElapsedMS(since: start))

                    _ = CustomLogger.perfStart()
                    Task.detached(priority: .utility) {
                        await ReadingOverridePolicy.shared.warmUp()
                    }
                    // CustomLogger.shared.perf("AppLaunch ReadingOverridePolicy.warmUp", elapsedMS: CustomLogger.perfElapsedMS(since: start))

                    _ = CustomLogger.perfStart()
                    await LegacyNotificationCleanup.runIfNeeded()
                    // CustomLogger.shared.perf("AppLaunch LegacyNotificationCleanup", elapsedMS: CustomLogger.perfElapsedMS(since: start))

                    _ = CustomLogger.perfStart()

                    let defaults = UserDefaults.standard
                    let enabled = defaults.bool(forKey: WordOfTheDayScheduler.enabledKey)
                    let hour = defaults.object(forKey: WordOfTheDayScheduler.hourKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.hourKey) : 9
                    let minute = defaults.object(forKey: WordOfTheDayScheduler.minuteKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.minuteKey) : 0
                    let words = store.allWords()
                    // CustomLogger.shared.perf("AppLaunch PrepareWordOfTheDayInputs", elapsedMS: CustomLogger.perfElapsedMS(since: start), details: "words=\(words.count) enabled=\(enabled)")

                    _ = CustomLogger.perfStart()
                    await WordOfTheDayScheduler.refreshScheduleIfEnabled(words: words, hour: hour, minute: minute, enabled: enabled)
                    // CustomLogger.shared.perf("AppLaunch WordOfTheDayScheduler.refreshScheduleIfEnabled", elapsedMS: CustomLogger.perfElapsedMS(since: scheduleStart), details: "words=\(words.count) enabled=\(enabled)")

                    // CustomLogger.shared.perf("AppLaunch Total", elapsedMS: CustomLogger.perfElapsedMS(since: launchTaskStart))
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
