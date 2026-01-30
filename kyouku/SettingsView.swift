import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var readingOverrides: ReadingOverridesStore

    @Environment(\.appColorTheme) private var appColorTheme
    @AppStorage(AppColorThemeID.storageKey) private var appColorThemeRaw: String = AppColorThemeID.defaultValue.rawValue

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingGlobalKerningPixels") private var readingGlobalKerningPixels: Double = 0
    /// Preferred base font PostScript name for reading text.
    /// Empty string means "System".
    @AppStorage("readingFontName") private var readingFontName: String = ""
    @AppStorage("readingDistinctKanaKanjiFonts") private var readingDistinctKanaKanjiFonts: Bool = false
    @AppStorage("readingHeadwordSpacingPadding") private var readingHeadwordSpacingPadding: Bool = false
    @AppStorage("readingAlternateTokenColorA") private var alternateTokenColorAHex: String = "#0A84FF"
    @AppStorage("readingAlternateTokenColorB") private var alternateTokenColorBHex: String = "#FF2D55"
    @AppStorage(FuriganaKnownWordSettings.modeKey) private var knownWordFuriganaModeRaw: String = FuriganaKnownWordSettings.defaultModeRawValue
    @AppStorage(FuriganaKnownWordSettings.scoreThresholdKey) private var knownWordFuriganaScoreThreshold: Double = FuriganaKnownWordSettings.defaultScoreThreshold
    @AppStorage(FuriganaKnownWordSettings.minimumReviewsKey) private var knownWordFuriganaMinimumReviews: Int = FuriganaKnownWordSettings.defaultMinimumReviews
    @AppStorage(CommonParticleSettings.storageKey) private var commonParticlesRaw: String = CommonParticleSettings.defaultRawValue

    @AppStorage("notesPreviewLineCount") private var notesPreviewLineCount: Int = 3

    @AppStorage(WordOfTheDayScheduler.enabledKey) private var wotdEnabled: Bool = false
    @AppStorage(WordOfTheDayScheduler.hourKey) private var wotdHour: Int = 9
    @AppStorage(WordOfTheDayScheduler.minuteKey) private var wotdMinute: Int = 0

    @AppStorage("debugViewMetricsHUD") private var debugViewMetricsHUD: Bool = false
    @AppStorage("rubyDebugRects") private var rubyDebugRects: Bool = false
    @AppStorage("rubyHeadwordDebugRects") private var rubyHeadwordDebugRects: Bool = false
    @AppStorage("rubyHeadwordLineBands") private var rubyHeadwordLineBands: Bool = false
    @AppStorage("rubyFuriganaLineBands") private var rubyFuriganaLineBands: Bool = false
    @AppStorage("debugDisableDictionaryPopup") private var debugDisableDictionaryPopup: Bool = false
    @AppStorage("debugTokenGeometryOverlay") private var debugTokenGeometryOverlay: Bool = false

    @State private var wotdAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var wotdPendingCount: Int = 0

    @State private var exportURL: URL? = nil
    @State private var isImporting: Bool = false
    @State private var importError: String? = nil
    @State private var importSummary: String? = nil

    @State private var previewAttributedText = NSAttributedString(string: SettingsView.previewSampleTextValue)
    @State private var previewRebuildTask: Task<Void, Never>? = nil
    @State private var previewAnnotatedSpans: [AnnotatedSpan]? = nil
    @State private var previewSemanticSpans: [SemanticSpan]? = nil
    @State private var previewSpansText: String? = nil
    @State private var previewValuesInitialized = false
    @State private var pendingReadingTextSize: Double = 17
    @State private var pendingReadingFuriganaSize: Double = 9
    @State private var pendingReadingLineSpacing: Double = 4

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "debugViewMetricsHUD") == nil,
           defaults.object(forKey: "rubyDebugHUD") != nil {
            defaults.set(defaults.bool(forKey: "rubyDebugHUD"), forKey: "debugViewMetricsHUD")
        }
        if defaults.object(forKey: "rubyHeadwordLineBands") == nil,
           defaults.bool(forKey: "rubyDebugLineBands") {
            defaults.set(true, forKey: "rubyHeadwordLineBands")
        }
        if defaults.object(forKey: "rubyFuriganaLineBands") == nil,
           defaults.bool(forKey: "rubyDebugLineBands") {
            defaults.set(true, forKey: "rubyFuriganaLineBands")
        }
    }

    private static let previewPlainLine = "かなだけのぎょうです。"
    private static let previewFuriganaLine = "京都で日本語を勉強しています。"
    private static let previewSampleTextValue = "\(previewPlainLine)\n\(previewFuriganaLine)"

    private struct ReadingFontOption: Identifiable {
        let id: String
        let title: String
        let postScriptName: String
    }

    private static let preferredJapaneseFontFamilies: [String] = [
        "Hiragino Sans",
        "Hiragino Mincho ProN",
        "YuGothic",
        "YuMincho",
        "Klee",
        "Tsukushi A Round Gothic",
        "Tsukushi B Round Gothic"
    ]

    private var readingFontOptions: [ReadingFontOption] {
        var options: [ReadingFontOption] = [
            .init(id: "system", title: "System", postScriptName: "")
        ]

        var seen: Set<String> = [""]
        for family in Self.preferredJapaneseFontFamilies {
            let names = UIFont.fontNames(forFamilyName: family).sorted()
            for postScriptName in names {
                guard seen.contains(postScriptName) == false else { continue }
                seen.insert(postScriptName)
                options.append(
                    .init(
                        id: postScriptName,
                        title: "\(family) — \(postScriptName)",
                        postScriptName: postScriptName
                    )
                )
            }
        }

        // If none of the preferred Japanese families are available (unlikely),
        // keep the picker functional with just System.
        return options
    }

    private var previewText: String {
        Self.previewSampleTextValue
    }

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("SQL Playground") {
                    SQLPlaygroundView()
                }
                appThemeSection
                textAppearanceSection
                furiganaBehaviorSection
                tokenHighlightSection
                notesSection
                extractFilterSection
                wordOfTheDaySection
                debugSection
                Section("Backup & Restore") {
                    Button("Export…") {
                        exportAll()
                    }
                    Button("Import…") {
                        isImporting = true
                    }
                    .tint(.red)
                }
            }
            .appThemedScrollBackground()
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                onCompletion: handleBackupImport
            )
            .sheet(isPresented: exportSheetBinding) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Text("Share Backup")
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .alert(
                "Import Error",
                isPresented: .constant(importError != nil),
                actions: { Button("OK") { importError = nil } },
                message: { Text(importError ?? "Unknown error") }
            )
            .alert("Import Summary", isPresented: importSummaryBinding) {
                Button("OK") { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
            .task { await initializePreviewValuesIfNeeded() }
            .task { await refreshWordOfTheDayStatus() }
            .onChange(of: readingTextSize) { _, newValue in syncPendingTextSize(to: newValue) }
            .onChange(of: readingFuriganaSize) { _, newValue in syncPendingFuriganaSize(to: newValue) }
            .onChange(of: readingLineSpacing) { _, newValue in syncPendingLineSpacing(to: newValue) }
            .onChange(of: readingHeadwordSpacingPadding) { _, _ in schedulePreviewRebuild() }
            .onDisappear { previewRebuildTask?.cancel() }
            .onChange(of: wotdEnabled) { _, _ in Task { await rescheduleWordOfTheDay() } }
            .onChange(of: wotdHour) { _, _ in Task { await rescheduleWordOfTheDay() } }
            .onChange(of: wotdMinute) { _, _ in Task { await rescheduleWordOfTheDay() } }
        }
        .appThemedRoot()
    }

    private var appThemeSection: some View {
        Section("App Theme") {
            Picker("Theme", selection: $appColorThemeRaw) {
                ForEach(AppColorThemeID.allCases) { themeID in
                    Text(themeID.displayName).tag(themeID.rawValue)
                }
            }

            HStack(spacing: 10) {
                themeSwatch(appColorTheme.palette.accent)
                themeSwatch(appColorTheme.palette.highlight)
                themeSwatch(appColorTheme.palette.textPrimary)
                themeSwatch(appColorTheme.palette.surface)
                themeSwatch(appColorTheme.palette.background)
                Spacer()
                Text(appColorTheme.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Theme preview")
        }
    }

    private func themeSwatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
    }

    private var textAppearanceSection: some View {
        Section("Reading Appearance") {
            RubyText(
                attributed: previewAttributedText,
                fontName: readingFontName.isEmpty ? nil : readingFontName,
                fontSize: CGFloat(pendingReadingTextSize),
                lineHeightMultiple: 1.0,
                extraGap: CGFloat(pendingReadingLineSpacing),
                isScrollEnabled: true,
                globalKerning: CGFloat(readingGlobalKerningPixels),
                padHeadwordSpacing: readingHeadwordSpacingPadding,
                rubyHorizontalAlignment: .center,
                enableTapInspection: false,
                distinctKanaKanjiFonts: readingDistinctKanaKanjiFonts
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 140, alignment: .leading)
            .padding(.vertical, 8)

            Toggle("Distinct kana/kanji fonts", isOn: $readingDistinctKanaKanjiFonts)
                .tint(Color.appAccent)

            Text("When enabled, kanji render in a Mincho-style font while kana keep your selected font.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            Picker("Font", selection: $readingFontName) {
                ForEach(readingFontOptions) { option in
                    Text(option.title).tag(option.postScriptName)
                }
            }

            HStack {
                Text("Text Size")
                Spacer()
                Text("\(Int(pendingReadingTextSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingTextSize },
                    set: { pendingReadingTextSize = $0; schedulePreviewRebuild() }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingTextSize = pendingReadingTextSize }
                }
            )
            HStack {
                Text("Furigana Size")
                Spacer()
                Text("\(Int(pendingReadingFuriganaSize))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingFuriganaSize },
                    set: { pendingReadingFuriganaSize = $0; schedulePreviewRebuild() }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingFuriganaSize = pendingReadingFuriganaSize }
                }
            )

            HStack {
                Text("Line Spacing")
                Spacer()
                Text("\(Int(pendingReadingLineSpacing))")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { pendingReadingLineSpacing },
                    set: { pendingReadingLineSpacing = $0 }
                ),
                in: 1...30,
                step: 1,
                onEditingChanged: { editing in
                    if editing == false { readingLineSpacing = pendingReadingLineSpacing }
                }
            )

            HStack {
                Text("Kerning")
                Spacer()
                Text(String(format: "%.2f px", readingGlobalKerningPixels))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $readingGlobalKerningPixels,
                in: -2.0...10.0,
                step: 0.25
            )

            Toggle("Pad headwords", isOn: $readingHeadwordSpacingPadding)
                .toggleStyle(.switch)

        }
    }

    private var tokenHighlightSection: some View {
        Section("Token Highlighting") {
            ColorPicker("Primary Token Color", selection: alternateTokenColorABinding, supportsOpacity: false)
            ColorPicker("Secondary Token Color", selection: alternateTokenColorBBinding, supportsOpacity: false)
        }
    }

    private var furiganaBehaviorSection: some View {
        let mode = FuriganaKnownWordMode(rawValue: knownWordFuriganaModeRaw) ?? .off

        return Section("Furigana") {
            Picker("Hide furigana", selection: $knownWordFuriganaModeRaw) {
                ForEach(FuriganaKnownWordMode.allCases) { m in
                    Text(m.title).tag(m.rawValue)
                }
            }

            Text(mode.detail + " (Applies to Paste view.)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if mode == .learned {
                Stepper(
                    value: $knownWordFuriganaMinimumReviews,
                    in: 1...50,
                    step: 1
                ) {
                    HStack {
                        Text("Minimum reviews")
                        Spacer()
                        Text("\(knownWordFuriganaMinimumReviews)")
                            .foregroundStyle(.secondary)
                    }
                }

                let pct = Int((max(0.0, min(1.0, knownWordFuriganaScoreThreshold)) * 100).rounded())
                HStack {
                    Text("Required Flashcards score")
                    Spacer()
                    Text("\(pct)%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $knownWordFuriganaScoreThreshold, in: 0.5...1.0, step: 0.05)

                Text("A word is considered learned only after at least \(max(1, knownWordFuriganaMinimumReviews)) reviews.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            Picker("Preview lines", selection: $notesPreviewLineCount) {
                ForEach(0...4, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
        }
    }

    private var extractFilterSection: some View {
        Section("Extract Filters") {
            ParticleTagEditor(tags: commonParticlesBinding)
        }
    }

    private var wordOfTheDaySection: some View {
        Section("Word of the Day") {
            Toggle("Daily notification", isOn: $wotdEnabled)

            DatePicker(
                "Time",
                selection: wotdTimeBinding,
                displayedComponents: [.hourAndMinute]
            )
            .disabled(wotdEnabled == false)

            HStack {
                Text("Permission")
                Spacer()
                Text(wotdPermissionLabel)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Scheduled")
                Spacer()
                Text("\(wotdPendingCount)")
                    .foregroundStyle(.secondary)
            }

            Button("Request Permission") {
                Task {
                    _ = await WordOfTheDayScheduler.requestAuthorization()
                    await refreshWordOfTheDayStatus()
                    await rescheduleWordOfTheDay()
                }
            }
            .disabled(wotdAuthStatus == .authorized || wotdAuthStatus == .provisional)

            Button("Schedule Now") {
                Task {
                    await rescheduleWordOfTheDay(force: true)
                }
            }
            .disabled(wotdEnabled == false)

            Button("Send Test Notification") {
                Task {
                    let word = wordsStore.allWords().randomElement()
                    await WordOfTheDayScheduler.sendTestNotification(word: word)
                    await refreshWordOfTheDayStatus()
                }
            }
            .disabled(wotdEnabled == false)
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            Toggle("Disable dictionary popup on tap", isOn: $debugDisableDictionaryPopup)
            Toggle("View metrics", isOn: $debugViewMetricsHUD)
            Toggle("Token geometry overlay", isOn: $debugTokenGeometryOverlay)
            Toggle("Headword debug rects", isOn: $rubyHeadwordDebugRects)
            Toggle("Ruby Debug Rects", isOn: $rubyDebugRects)
            Toggle("Headword line bands", isOn: $rubyHeadwordLineBands)
            Toggle("Ruby line bands", isOn: $rubyFuriganaLineBands)
        }
    }

    private var commonParticlesBinding: Binding<[String]> {
        Binding(
            get: { CommonParticleSettings.decodeList(from: commonParticlesRaw) },
            set: { commonParticlesRaw = CommonParticleSettings.encodeList($0) }
        )
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { exportURL != nil },
            set: { if $0 == false { exportURL = nil } }
        )
    }

    private var importSummaryBinding: Binding<Bool> {
        Binding(
            get: { importSummary != nil },
            set: { if $0 == false { importSummary = nil } }
        )
    }

    private func handleBackupImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer {
                if needsStop {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                let backup = try AppDataBackup.importData(from: url)
                wordsStore.replaceAll(with: backup.words)
                notesStore.replaceAll(with: backup.notes)
                readingOverrides.replaceAll(with: backup.readingOverrides)
                NotificationCenter.default.post(name: .didImportNotesBackup, object: backup.notes)
                importSummary = "Imported \(backup.words.count) words, \(backup.notes.count) notes, and \(backup.readingOverrides.count) reading overrides."
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    private func exportAll() {
        do {
            let words = wordsStore.allWords()
            let notes = notesStore.allNotes()
            let overrides = readingOverrides.allOverrides()
            exportURL = try AppDataBackup.exportData(words: words, notes: notes, readingOverrides: overrides)
        } catch {
            importError = error.localizedDescription
        }
    }

    @MainActor
    private func initializePreviewValuesIfNeeded() async {
        guard previewValuesInitialized == false else { return }
        previewValuesInitialized = true

        pendingReadingTextSize = readingTextSize
        pendingReadingFuriganaSize = readingFuriganaSize
        pendingReadingLineSpacing = readingLineSpacing
        _ = await ensurePreviewStage2(for: previewText)
        schedulePreviewRebuild()
    }

    private func syncPendingTextSize(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingTextSize - newValue) > .ulpOfOne {
            pendingReadingTextSize = newValue
            schedulePreviewRebuild()
        }
    }

    private func syncPendingFuriganaSize(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingFuriganaSize - newValue) > .ulpOfOne {
            pendingReadingFuriganaSize = newValue
            schedulePreviewRebuild()
        }
    }

    private func syncPendingLineSpacing(to newValue: Double) {
        guard previewValuesInitialized else { return }
        if abs(pendingReadingLineSpacing - newValue) > .ulpOfOne {
            pendingReadingLineSpacing = newValue
        }
    }

    private var alternateTokenColorABinding: Binding<Color> {
        Binding(
            get: { Color(hexString: alternateTokenColorAHex, fallback: Color(UIColor.systemBlue)) },
            set: { newColor in
                if let hex = newColor.hexString() {
                    alternateTokenColorAHex = hex
                }
            }
        )
    }

    private var alternateTokenColorBBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: alternateTokenColorBHex, fallback: Color(UIColor.systemPink)) },
            set: { newColor in
                if let hex = newColor.hexString() {
                    alternateTokenColorBHex = hex
                }
            }
        )
    }

    private func schedulePreviewRebuild() {
        let text = previewText
        let textSize = pendingReadingTextSize
        let furiganaSize = pendingReadingFuriganaSize
        let spacingEnabled = readingHeadwordSpacingPadding

        previewRebuildTask?.cancel()
        previewRebuildTask = Task {
            await rebuildPreviewAttributedText(
                text: text,
                textSize: textSize,
                furiganaSize: furiganaSize,
                padHeadwordSpacing: spacingEnabled
            )
        }
    }

    private var wotdTimeBinding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                var comps = calendar.dateComponents([.year, .month, .day], from: Date())
                comps.hour = wotdHour
                comps.minute = wotdMinute
                return calendar.date(from: comps) ?? Date()
            },
            set: { newValue in
                let calendar = Calendar.current
                let comps = calendar.dateComponents([.hour, .minute], from: newValue)
                wotdHour = comps.hour ?? 9
                wotdMinute = comps.minute ?? 0
            }
        )
    }

    private var wotdPermissionLabel: String {
        switch wotdAuthStatus {
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    private func refreshWordOfTheDayStatus() async {
        wotdAuthStatus = await WordOfTheDayScheduler.authorizationStatus()
        wotdPendingCount = await WordOfTheDayScheduler.pendingWordOfTheDayRequestCount()
    }

    private func rescheduleWordOfTheDay(force: Bool = false) async {
        if force {
            await WordOfTheDayScheduler.clearPendingWordOfTheDayRequests()
        }
        let words = wordsStore.allWords()
        await WordOfTheDayScheduler.refreshScheduleIfEnabled(
            words: words,
            hour: wotdHour,
            minute: wotdMinute,
            enabled: wotdEnabled,
            daysToSchedule: 14
        )
        await refreshWordOfTheDayStatus()
    }

    private func rebuildPreviewAttributedText(
        text: String,
        textSize: Double,
        furiganaSize: Double,
        padHeadwordSpacing: Bool
    ) async {
        let stage2 = await ensurePreviewStage2(for: text)
        if Task.isCancelled { return }
        let attributed = FuriganaAttributedTextBuilder.project(
            text: text,
            semanticSpans: stage2.semantic,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: "SettingsPreview",
            padHeadwordSpacing: padHeadwordSpacing
        )
        if Task.isCancelled { return }
        await MainActor.run {
            previewAttributedText = attributed
        }
    }

    private func ensurePreviewStage2(for text: String) async -> (annotated: [AnnotatedSpan], semantic: [SemanticSpan]) {
        let cached = await MainActor.run(body: { () -> (String?, [AnnotatedSpan]?, [SemanticSpan]?) in
            (previewSpansText, previewAnnotatedSpans, previewSemanticSpans)
        })
        if cached.0 == text, let annotated = cached.1, let semantic = cached.2 {
            return (annotated: annotated, semantic: semantic)
        }

        do {
            let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                text: text,
                context: "SettingsPreview",
                tokenBoundaries: [],
                readingOverrides: [],
                baseSpans: nil
            )
            await MainActor.run {
                previewAnnotatedSpans = stage2.annotatedSpans
                previewSemanticSpans = stage2.semanticSpans
                previewSpansText = text
            }
            return (annotated: stage2.annotatedSpans, semantic: stage2.semanticSpans)
        } catch {
            await MainActor.run {
                previewAnnotatedSpans = []
                previewSemanticSpans = []
                previewSpansText = text
            }
            return (annotated: [], semantic: [])
        }
    }
}

enum CommonParticleSettings {
    static let storageKey = "extractCommonParticles"
    static let defaultValues: [String] = [
        "は", "が", "を", "に", "へ", "で", "と", "も", "や", "ね", "よ", "な", "の"
    ]
    static let defaultRawValue: String = defaultValues.joined(separator: ",")

    static func decodeList(from rawValue: String) -> [String] {
        let source = rawValue.isEmpty ? defaultRawValue : rawValue
        return source
            .components(separatedBy: separatorCharacterSet)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    static func encodeList(_ list: [String]) -> String {
        list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: ",")
    }

    static func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let separatorCharacterSet = CharacterSet(charactersIn: ",\n\r\t")
}

private struct ParticleTagEditor: View {
    @Binding var tags: [String]
    @State private var draft: String = ""

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 70), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tags.isEmpty {
                Text("No particles configured yet. Add particles to hide them from the Extract Words list when filtering is enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(for: tag)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add particle", text: $draft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { commitDraft() }

                Button("Add") { commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(CommonParticleSettings.normalizedToken(draft).isEmpty)
            }

            Text("Tap a tag’s × button to remove it. These values inform the ‘Hide common particles’ filter in Extract Words.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tagChip(for tag: String) -> some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.subheadline)
            Button(role: .destructive) {
                remove(tag: tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func commitDraft() {
        let normalized = CommonParticleSettings.normalizedToken(draft)
        guard normalized.isEmpty == false else { return }
        if tags.contains(normalized) == false {
            tags.append(normalized)
            tags.sort()
        }
        draft = ""
    }

    private func remove(tag: String) {
        tags.removeAll { $0 == tag }
    }
}

extension Notification.Name {
    static let didImportNotesBackup = Notification.Name("didImportNotesBackup")
}
