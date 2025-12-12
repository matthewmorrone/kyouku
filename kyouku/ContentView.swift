//
//  ContentView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            PasteView()
                .tabItem {
                    Label("Paste", systemImage: "text.page")
                }
                .tag(AppTab.paste)
            
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "book")
                }
                .tag(AppTab.notes)

            SavedWordsView()
                .tabItem {
                    Label("Words", systemImage: "checklist")
                }
                .tag(AppTab.words)
            
            FlashcardsView()
                .tabItem {
                    Label("Cards", systemImage: "rectangle.on.rectangle.angled")
                }
                .tag(AppTab.cards)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
    }
}
