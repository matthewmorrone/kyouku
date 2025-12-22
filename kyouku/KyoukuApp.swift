//
//  KyoukuApp.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25
//

import SwiftUI

@main
struct KyoukuApp: App {
    @StateObject var notes = NotesStore()
    @StateObject var store = WordsStore()
    @StateObject var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notes)
                .environmentObject(store)
                .environmentObject(router)
                .onOpenURL { url in
                    // Expect kyouku://inbox to route to Paste tab; PasteView will ingest on appear/activation
                    if url.scheme == "kyouku" && url.host == "inbox" {
                        router.selectedTab = .paste
                    }
                }
        }
    }
}
