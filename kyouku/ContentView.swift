//
//  ContentView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var store: WordsStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppColorThemeID.storageKey) private var appColorThemeRaw: String = AppColorThemeID.defaultValue.rawValue
    @AppStorage("debugPixelRulerOverlay") private var debugPixelRulerOverlay: Bool = false

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

            CardsTabView()
                .tabItem {
                    Label("Study", systemImage: "rectangle.on.rectangle.angled")
                }
                .tag(AppTab.cards)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }

        let overlay = Group {
            if debugPixelRulerOverlay {
                PixelRulerOverlayView()
                    .ignoresSafeArea()
            }
        }

        return Group {
            if appColorTheme.id == .systemDefault {
                ZStack {
                    tabView
                        .environment(\.appColorTheme, appColorTheme)
                        .appThemedRoot(themeID: appColorTheme.id)
                    overlay
                }
            } else {
                ZStack {
                    tabView
                        .tint(appColorTheme.palette.accent)
                        .environment(\.appColorTheme, appColorTheme)
                        .appThemedRoot(themeID: appColorTheme.id)
                    overlay
                }
            }
        }
        .onAppear {
            let start = CustomLogger.perfStart()
            store.pruneMissingNoteAssociations(validNoteIDs: Set(notesStore.notes.map(\.id)))
            // CustomLogger.shared.perf("ContentView onAppear pruneMissingNoteAssociations", elapsedMS: CustomLogger.perfElapsedMS(since: start), details: "notes=\(notesStore.notes.count)")
        }
        .onChange(of: notesStore.notes.map(\.id)) { _, newIDs in
            let start = CustomLogger.perfStart()
            store.pruneMissingNoteAssociations(validNoteIDs: Set(newIDs))
            // CustomLogger.shared.perf("ContentView onChange pruneMissingNoteAssociations", elapsedMS: CustomLogger.perfElapsedMS(since: start), details: "noteIDs=\(newIDs.count)")
        }
    }
}
