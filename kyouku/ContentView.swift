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
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .tag(AppTab.paste)
            
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(AppTab.notes)
            
            FlashcardsView()
                .tabItem {
                    Label("Cards", systemImage: "rectangle.on.rectangle.angled")
                }
                .tag(AppTab.cards)
            
            SavedWordsView()
                .tabItem {
                    Label("Words", systemImage: "book")
                }
                .tag(AppTab.words)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
    }
}
