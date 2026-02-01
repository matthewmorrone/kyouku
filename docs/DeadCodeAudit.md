# Dead/Unused Code Audit (Heuristic)

This is a best-effort static audit (not a Swift parser). Treat results as **candidates for manual review**, not safe deletions.

## Scope

- App Swift files: 94
- Test Swift files: 10

## Candidates: no declared type referenced elsewhere

- kyouku/DictionarySurfaceMatcher.swift — declared: DictionarySurfaceMatcher:0
- kyouku/EmbeddingDebugIntrospection.swift — declared: EmbeddingDebugIntrospection:0
- kyouku/PhysicsFlashcardsDemoView.swift — declared: InteractionMode:0, PhysicsFlashcard:0, PhysicsFlashcardView:0, PhysicsFlashcardsDeckView:0, PhysicsFlashcardsDeckViewController:0, PhysicsFlashcardsDemoView:0
- kyouku/TokenEmbeddingResolver.swift — declared: TokenEmbeddingRange:0, TokenEmbeddingResolver:0, TokenWithRange:0
- kyouku/AppThemeViewModifiers.swift — declared: AppThemedRootModifier:0, AppThemedScrollBackgroundModifier:0
- kyouku/RoundedBorder.swift — declared: RoundedBorderModifier:0

## Candidates: extension-only file (extended types never referenced elsewhere)

- None found by this heuristic.

## Candidates: declared types referenced in exactly 1 other file

- kyouku/AppColorTheme.swift: Palette (1)
- kyouku/AppDataBackup.swift: AppDataBackup (1)
- kyouku/AppRouter.swift: AppTab (1)
- kyouku/AppThemeColors.swift: AppTheme (1)
- kyouku/CoreTextRubyText.swift: CoreTextRubyText (1)
- kyouku/DeinflectionCache.swift: DeinflectionCache (1)
- kyouku/DeinflectionHardStopMerger.swift: DeinflectionHardStopMerger (1)
- kyouku/Deinflector.swift: Rule (1)
- kyouku/DictionaryEntry.swift: DictionaryEntryForm (1)
- kyouku/DictionaryEntry.swift: ExampleSentence (1)
- kyouku/DictionaryEntry.swift: SurfaceReadingOverride (1)
- kyouku/DictionaryEntry.swift: isolation (1)
- kyouku/DictionaryEntryResolver.swift: DictionaryEntryResolver (1)
- kyouku/DictionaryLookupViewModel.swift: PresentedLookup (1)
- kyouku/DictionarySQLiteError.swift: DictionarySQLiteError (1)
- kyouku/EmbeddingAccessSession.swift: EmbeddingSession (1)
- kyouku/EmbeddingBoundaryScorer.swift: EmbeddingBoundaryScorer (1)
- kyouku/EmbeddingFeatureFlags.swift: EmbeddingFeatureFlags (1)
- kyouku/EmbeddingFeatureGates.swift: EmbeddingFeature (1)
- kyouku/EmbeddingLRUCache.swift: EmbeddingLRUCache (1)
- kyouku/EmbeddingLRUCache.swift: Node (1)
- kyouku/EmbeddingNeighborhoodPrefetcher.swift: EmbeddingNeighborhoodPrefetcher (1)
- kyouku/EmbeddingsSQLiteBatchReader.swift: Connection (1)
- kyouku/EmbeddingsSQLiteBatchReader.swift: EmbeddingsSQLiteBatchReader (1)
- kyouku/EmbeddingsSQLiteBatchReader.swift: PoolState (1)
- kyouku/EmbeddingsSQLiteStore.swift: Connection (1)
- kyouku/EmbeddingsSQLiteStore.swift: PoolState (1)
- kyouku/ExtractWordsView.swift: ExtractWordsView (1)
- kyouku/ExtractWordsView.swift: TokenListItem (1)
- kyouku/FlashcardsView.swift: FlashcardsView (1)
- kyouku/FlashcardsView.swift: GestureMode (1)
- kyouku/FuriganaAttributedTextBuilder.swift: Stage2Result (1)
- kyouku/FuriganaRenderingHost.swift: FuriganaRenderingHost (1)
- kyouku/FuriganaRubyProjector.swift: FuriganaRubyProjector (1)
- kyouku/FuriganaSpanResolver.swift: Source (1)
- kyouku/LegacyNotificationCleanup.swift: LegacyNotificationCleanup (1)
- kyouku/LexiconTrie.swift: Node (1)
- kyouku/LiveSemanticFeedbackBadge.swift: LiveSemanticFeedbackBadge (1)
- kyouku/MorphologicalIntegrityGate.swift: MorphologicalIntegrityGate (1)
- kyouku/NaturalLanguageSupport.swift: DetectedGrammarPattern (1)
- kyouku/NaturalLanguageSupport.swift: GrammarPatternDetector (1)
- kyouku/NaturalLanguageSupport.swift: JapaneseSimilarityService (1)
- kyouku/NaturalLanguageSupport.swift: SentenceContextExtractor (1)
- kyouku/NoteClozeStudyView.swift: NoteClozeStudyView (1)
- kyouku/NoteClozeStudyViewModel.swift: Blank (1)
- kyouku/NotesView.swift: NotesView (1)
- kyouku/NotificationDeepLinkHandler.swift: NotificationDeepLinkHandler (1)
- kyouku/PasteBufferStore.swift: PasteBufferStore (1)
- kyouku/PasteTextTransforms.swift: PasteTextTransforms (1)
- kyouku/PasteView.swift: Bucket (1)
- kyouku/PasteView.swift: LiveSemanticFeedback (1)
- kyouku/ReduplicationGate.swift: ReduplicationGate (1)
- kyouku/RubyText.swift: RubyAnnotationVisibility (1)
- kyouku/RubyText.swift: SplitPaneScrollSyncStore (1)
- kyouku/RubyText.swift: TokenOverlayTextView (1)
- kyouku/SQLPlaygroundExecutor.swift: SQLPlaygroundExecutor (1)
- kyouku/SQLPlaygroundView.swift: SQLPlaygroundView (1)
- kyouku/SelectionSpanResolver.swift: SelectionSpanCandidate (1)
- kyouku/SemanticConstellationView.swift: SemanticConstellationSheet (1)
- kyouku/SemanticNeighborhoodExplorerView.swift: SemanticNeighborhoodExplorerView (1)
- kyouku/SettingsView.swift: CommonParticleSettings (1)
- kyouku/SpanReadingAttacher.swift: SpanReadingAttacher (1)
- kyouku/SwipeableFlashcardsMinimalView.swift: GestureMode (1)
- kyouku/ThemeClustering.swift: ThemeClustering (1)
- kyouku/ThemeDiscoveryTypes.swift: ThemeDiscoveryState (1)
- kyouku/ThemeDiscoveryTypes.swift: ThemeNoteEmbeddingSnapshot (1)
- kyouku/ThemeLabeler.swift: ThemeLabeler (1)
- kyouku/ThemesView.swift: ThemesView (1)
- kyouku/TokenBoundariesStore.swift: StoredSpan (1)
- kyouku/TokenSelectionController.swift: TokenSelectionController (1)
- kyouku/WordCreateView.swift: WordCreateView (1)
- kyouku/WordDefinitionsView.swift: Bucket (1)
- kyouku/WordDefinitionsView.swift: TokenPart (1)
- kyouku/WordEditView.swift: WordEditView (1)
- kyouku/WordsView.swift: WordsView (1)

## Bundled resources: referenced via string literals

- kyouku/deinflect.min.json: filename literal in 0 file(s); resource-name literal "deinflect.min" in 1 file(s)
- kyouku/dictionary.sqlite3: filename literal in 0 file(s); resource-name literal "dictionary" in 7 file(s)

## Next steps (recommended)

- For higher confidence, run a dedicated unused-code tool like Periphery against the Xcode project (it understands Swift better than regex heuristics).
- Before deleting any Swift file, confirm it is not referenced via SwiftUI view construction, environment injection, reflection, string-based lookups, or previews.
