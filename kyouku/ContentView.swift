//
//  ContentView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppColorThemeID.storageKey) private var appColorThemeRaw: String = AppColorThemeID.defaultValue.rawValue

    private var appColorTheme: AppColorTheme {
        AppColorTheme.from(rawValue: appColorThemeRaw, colorScheme: colorScheme)
    }

    var body: some View {
        let tabView = TabView(selection: $router.selectedTab) {
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

            WordsView()
                .tabItem {
                    Label("Words", systemImage: "text.book.closed.fill")
                }
                .tag(AppTab.dictionary)

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

        if appColorTheme.id == .systemDefault {
            tabView
                .environment(\.appColorTheme, appColorTheme)
                .appThemedRoot(themeID: appColorTheme.id)
        } else {
            tabView
                .tint(appColorTheme.palette.accent)
                .environment(\.appColorTheme, appColorTheme)
                .appThemedRoot(themeID: appColorTheme.id)
        }
    }
}
