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
        let appInitStart = CustomLogger.perfStart()

        let overridesStart = CustomLogger.perfStart()
        let overrides = ReadingOverridesStore()
        // CustomLogger.shared.perf("AppInit ReadingOverridesStore", elapsedMS: CustomLogger.perfElapsedMS(since: overridesStart))

        _readingOverrides = StateObject(wrappedValue: overrides)

        let tokenBoundariesStart = CustomLogger.perfStart()
        _tokenBoundaries = StateObject(wrappedValue: TokenBoundariesStore())
        // CustomLogger.shared.perf("AppInit TokenBoundariesStore", elapsedMS: CustomLogger.perfElapsedMS(since: tokenBoundariesStart))

        let notesStart = CustomLogger.perfStart()
        _notes = StateObject(wrappedValue: NotesStore(readingOverrides: overrides))
        // CustomLogger.shared.perf("AppInit NotesStore", elapsedMS: CustomLogger.perfElapsedMS(since: notesStart))

        let wordsStart = CustomLogger.perfStart()
        _store = StateObject(wrappedValue: WordsStore())
        // CustomLogger.shared.perf("AppInit WordsStore", elapsedMS: CustomLogger.perfElapsedMS(since: wordsStart))

        let routerStart = CustomLogger.perfStart()
        let router = AppRouter()
        // CustomLogger.shared.perf("AppInit AppRouter", elapsedMS: CustomLogger.perfElapsedMS(since: routerStart))
        _router = StateObject(wrappedValue: router)

        // Retain a UNUserNotificationCenter delegate that can deep-link into the app.
        let deepLinkStart = CustomLogger.perfStart()
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
                    let launchTaskStart = CustomLogger.perfStart()

                    // Ensure the handler is retained for the app lifetime.
                    let retainHandlerStart = CustomLogger.perfStart()
                    _ = notificationDeepLinkHandler
                    // CustomLogger.shared.perf("AppLaunch RetainDeepLinkHandler", elapsedMS: CustomLogger.perfElapsedMS(since: retainHandlerStart))

                    let warmUpStart = CustomLogger.perfStart()
                    Task.detached(priority: .utility) {
                        await ReadingOverridePolicy.shared.warmUp()
                    }
                    // CustomLogger.shared.perf("AppLaunch ReadingOverridePolicy.warmUp", elapsedMS: CustomLogger.perfElapsedMS(since: warmUpStart))

                    let cleanupStart = CustomLogger.perfStart()
                    await LegacyNotificationCleanup.runIfNeeded()
                    // CustomLogger.shared.perf("AppLaunch LegacyNotificationCleanup", elapsedMS: CustomLogger.perfElapsedMS(since: cleanupStart))

                    let defaultsStart = CustomLogger.perfStart()

                    let defaults = UserDefaults.standard
                    let enabled = defaults.bool(forKey: WordOfTheDayScheduler.enabledKey)
                    let hour = defaults.object(forKey: WordOfTheDayScheduler.hourKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.hourKey) : 9
                    let minute = defaults.object(forKey: WordOfTheDayScheduler.minuteKey) != nil ? defaults.integer(forKey: WordOfTheDayScheduler.minuteKey) : 0
                    let words = store.allWords()
                    // CustomLogger.shared.perf("AppLaunch PrepareWordOfTheDayInputs", elapsedMS: CustomLogger.perfElapsedMS(since: defaultsStart), details: "words=\(words.count) enabled=\(enabled)")

                    let scheduleStart = CustomLogger.perfStart()
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
