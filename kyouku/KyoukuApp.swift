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

    init() {
        let overrides = ReadingOverridesStore()
        _readingOverrides = StateObject(wrappedValue: overrides)
        _tokenBoundaries = StateObject(wrappedValue: TokenBoundariesStore())
        _notes = StateObject(wrappedValue: NotesStore(readingOverrides: overrides))
        _store = StateObject(wrappedValue: WordsStore())
        _router = StateObject(wrappedValue: AppRouter())
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
                    await ReadingOverridePolicy.shared.warmUp()
                    await LegacyNotificationCleanup.runIfNeeded()
                }
        }
    }
}
