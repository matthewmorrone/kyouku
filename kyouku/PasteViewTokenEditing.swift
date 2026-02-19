import SwiftUI
import UIKit
import Foundation

extension PasteView {

    // Overloaded hasSavedWord with explicit noteID
    func hasSavedWord(surface: String, reading: String?, noteID: UUID?) -> Bool {
        let targetSurface = kanaFoldToHiragana(surface)
        let targetKana = kanaFoldToHiragana(reading)
        return words.words.contains { word in
            guard word.isAssociated(with: noteID) else { return false }
            guard kanaFoldToHiragana(word.surface) == targetSurface else { return false }
            // If we don't know the reading for this token, match on surface alone.
            // This keeps the Extract Words star button reliable (no "can't bookmark" feeling).
            if let targetKana {
                return kanaFoldToHiragana(word.kana) == targetKana
            }
            return true
        }
    }

    func hasSavedWord(surface: String, reading: String?) -> Bool {
        hasSavedWord(surface: surface, reading: reading, noteID: currentNote?.id)
    }

    func tokenDuplicateKey(surface: String, reading: String?) -> String {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedSurface)|\(normalizedReading)"
    }

    func defineWord(using entry: DictionaryEntry) {
        guard let selection = tokenSelection else { return }
        let surface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let gloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
        guard surface.isEmpty == false, gloss.isEmpty == false else { return }
        words.add(surface: surface, kana: entry.kana, meaning: gloss, note: nil, sourceNoteID: currentNote?.id)
    }

    func neighborIndex(for index: Int, direction: MergeDirection) -> Int? {
        switch direction {
        case .previous:
            return index - 1
        case .next:
            return index + 1
        }
    }

    func mergeSpan(at index: Int, direction: MergeDirection) {
        let wasShowingTokensPopover = showTokensPopover
        guard let mergeRange = stage1MergeRange(forSemanticIndex: index, direction: direction) else { return }
        let union: NSRange? = {
            if propagateTokenEdits {
                return applySpanMergeEverywhere(mergeRange: mergeRange, actionName: "Merge Tokens")
            }
            return applySpanMerge(mergeRange: mergeRange, actionName: "Merge Tokens")
        }()
        guard let union else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union

        // `index` is a semantic-span index (into `furiganaSemanticSpans`).
        // `mergeRange` is a Stage-1 span index range.
        // Keep the selection in semantic space; otherwise merging from the token list
        // can jump the selection to the wrong token (index-space mismatch).
        let mergedStage1Index = mergeRange.lowerBound
        let mergedSemanticIndex: Int = {
            switch direction {
            case .previous:
                return max(0, index - 1)
            case .next:
                return index
            }
        }()
        let textStorage = inputText as NSString
        guard NSMaxRange(union) <= textStorage.length else { return }
        let surface = textStorage.substring(with: union)
        let semantic = SemanticSpan(range: union, surface: surface, sourceSpanIndices: mergedStage1Index..<(mergedStage1Index + 1), readingKana: nil)
        let ephemeral = AnnotatedSpan(span: TextSpan(range: union, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [])
        let ctx = TokenSelectionContext(tokenIndex: mergedSemanticIndex, range: union, surface: surface, semanticSpan: semantic, sourceSpanIndices: semantic.sourceSpanIndices, annotatedSpan: ephemeral)
        tokenSelection = ctx
        if sheetDictionaryPanelEnabled {
            sheetSelection = ctx
            // If the Extract Words sheet is open, do not present another sheet.
            // The token list sheet renders an in-sheet dictionary panel via `sheetSelection`.
            if wasShowingTokensPopover == false {
                isDictionarySheetPresented = true
            }
        }
        showTokensPopover = wasShowingTokensPopover
    }

    func startSplitFlow(for index: Int) {
        guard furiganaSemanticSpans.indices.contains(index) else { return }
        let semantic = furiganaSemanticSpans[index]
        guard let trimmed = trimmedRangeAndSurface(for: semantic.range), trimmed.range.length > 1 else { return }
        presentDictionaryForSpan(at: index, focusSplitMenu: true)
    }

    func canMergeSpan(at index: Int, direction: MergeDirection) -> Bool {
        stage1MergeRange(forSemanticIndex: index, direction: direction) != nil
    }

    func handleOverridesExternalChange() {
        let signature = computeOverrideSignature()
        guard signature != overrideSignature else { return }
        // CustomLogger.shared.debug("Override change detected for note=\(activeNoteID)")
        overrideSignature = signature
        updateCustomizedRanges()
        guard inputText.isEmpty == false else { return }
        guard showFurigana || tokenHighlightsEnabled else { return }
        triggerFuriganaRefreshIfNeeded(reason: "reading overrides changed", recomputeSpans: true)
    }

    func computeOverrideSignature() -> Int {
        let overrides = readingOverrides.overrides(for: activeNoteID).filter { $0.userKana != nil }.sorted { lhs, rhs in
            if lhs.rangeStart == rhs.rangeStart {
                return lhs.rangeLength < rhs.rangeLength
            }
            return lhs.rangeStart < rhs.rangeStart
        }
        var hasher = Hasher()
        hasher.combine(overrides.count)
        for override in overrides {
            hasher.combine(override.rangeStart)
            hasher.combine(override.rangeLength)
            hasher.combine(override.userKana ?? "")
        }
        return hasher.finalize()
    }

    func updateCustomizedRanges() {
        var ranges = readingOverrides.overrides(for: activeNoteID).filter { $0.userKana != nil }.map { $0.nsRange }

        if tokenBoundaries.hasCustomSpans(for: activeNoteID) {
            ranges.append(contentsOf: tokenBoundaries.storedRanges(for: activeNoteID))
        }

        customizedRanges = ranges
    }

    func applyDictionaryReading(_ entry: DictionaryEntry) {
        guard let selection = tokenSelection else { return }

        let tokenSurface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenSurface.isEmpty == false else { return }

        let tokenSuffix = trailingKanaSuffix(in: tokenSurface)

        let lemmaSurface: String = {
            let kanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
            if kanji.isEmpty == false { return kanji }
            let kana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return kana
        }()

        let lemmaSuffix = trailingKanaSuffix(in: lemmaSurface)
        let baseReading = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Heuristic: if both lemma and token have okurigana, treat the lemma's okurigana
        // as a suffix in the reading and swap it for the token's okurigana.
        // Example: 抱く(だく) -> 抱かれ(だかれ)
        let surfaceReading: String = {
            guard baseReading.isEmpty == false else { return "" }
            guard let tokenSuffix, tokenSuffix.isEmpty == false else { return baseReading }
            guard let lemmaSuffix, lemmaSuffix.isEmpty == false else { return baseReading }
            guard baseReading.hasSuffix(lemmaSuffix) else { return baseReading }
            let stem = String(baseReading.dropLast(lemmaSuffix.count))
            return stem + tokenSuffix
        }()

        // Store only the kanji reading portion for mixed kanji-kana tokens so ruby
        // can render like 抱(だ)かれ instead of treating the whole surface as ruby.
        let overrideKana: String = {
            guard let tokenSuffix, tokenSuffix.isEmpty == false else { return surfaceReading }
            guard surfaceReading.hasSuffix(tokenSuffix) else { return surfaceReading }
            let storage = tokenSurface as NSString
            // If the token is entirely kana, don't strip; it would produce empty.
            if isKanaOnlySurface(tokenSurface) { return surfaceReading }
            // Ensure there is at least one non-kana scalar before stripping.
            if storage.length <= tokenSuffix.utf16.count { return surfaceReading }
            return String(surfaceReading.dropLast(tokenSuffix.count))
        }()

        let trimmedKana = overrideKana.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKana.isEmpty == false else { return }

        let targetRanges: [NSRange] = {
            guard propagateTokenEdits else { return [selection.range] }
            return propagatedTokenRanges(referenceRange: selection.range, referenceSurface: selection.surface)
        }()

        let overrides: [ReadingOverride] = targetRanges.map { r in
            ReadingOverride(
                noteID: activeNoteID,
                rangeStart: r.location,
                rangeLength: r.length,
                userKana: trimmedKana
            )
        }
        applyOverridesChange(removing: targetRanges, adding: overrides, actionName: "Apply Reading")
    }

    func applyCustomReading(_ kana: String) {
        guard let selection = tokenSelection else { return }
        let trimmed = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let normalized = normalizeOverrideKana(trimmed)
        guard normalized.isEmpty == false else { return }

        let override = ReadingOverride(
            noteID: activeNoteID,
            rangeStart: selection.range.location,
            rangeLength: selection.range.length,
            userKana: normalized
        )

        if propagateTokenEdits {
            let targetRanges = propagatedTokenRanges(referenceRange: selection.range, referenceSurface: selection.surface)
            let overrides: [ReadingOverride] = targetRanges.map { r in
                ReadingOverride(
                    noteID: activeNoteID,
                    rangeStart: r.location,
                    rangeLength: r.length,
                    userKana: normalized
                )
            }
            applyOverridesChange(removing: targetRanges, adding: overrides, actionName: "Apply Custom Reading")
        } else {
            applyOverridesChange(removing: [selection.range], adding: [override], actionName: "Apply Custom Reading")
        }
    }

    func propagatedTokenRanges(referenceRange: NSRange, referenceSurface: String) -> [NSRange] {
        let nsText = inputText as NSString
        guard nsText.length > 0 else { return [referenceRange] }

        let targetSurface = referenceSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetSurface.isEmpty == false else { return [referenceRange] }

        // Use semantic spans (post-Stage-2.5 + tail merge) so reading overrides follow
        // the currently visible/selected tokenization.
        var out: [NSRange] = []
        out.reserveCapacity(min(64, furiganaSemanticSpans.count))
        for span in furiganaSemanticSpans {
            let r = span.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            guard NSMaxRange(r) <= nsText.length else { continue }
            let surface = nsText.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if surface == targetSurface {
                out.append(r)
            }
        }

        // Fallback: if tokenization is unavailable/unexpected, at least apply to the current selection.
        if out.isEmpty {
            return [referenceRange]
        }
        return out
    }

    func normalizeOverrideKana(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func mergeSelection(_ direction: MergeDirection) {
        let wasShowingTokensPopover = showTokensPopover
        guard let selection = tokenSelection else { return }
        guard let mergeRange = stage1MergeRange(forSemanticIndex: selection.tokenIndex, direction: direction) else { return }
        let union: NSRange? = {
            if propagateTokenEdits {
                return applySpanMergeEverywhere(mergeRange: mergeRange, actionName: "Merge Tokens")
            }
            return applySpanMerge(mergeRange: mergeRange, actionName: "Merge Tokens")
        }()
        guard let union else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union
        pendingSplitFocusSelectionID = nil

        // `TokenSelectionContext.tokenIndex` is a semantic-span index (into `furiganaSemanticSpans`).
        // `mergeRange` is a Stage-1 span index range.
        // After merging, keep the selection's tokenIndex in semantic space so subsequent
        // merge/split actions still resolve correctly.
        let mergedStage1Index = mergeRange.lowerBound
        let mergedSemanticIndex: Int = {
            switch direction {
            case .previous:
                return max(0, selection.tokenIndex - 1)
            case .next:
                return selection.tokenIndex
            }
        }()
        let textStorage = inputText as NSString
        guard NSMaxRange(union) <= textStorage.length else { return }
        let surface = textStorage.substring(with: union)
        let semantic = SemanticSpan(range: union, surface: surface, sourceSpanIndices: mergedStage1Index..<(mergedStage1Index + 1), readingKana: nil)
        let ephemeral = AnnotatedSpan(span: TextSpan(range: union, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [])
        let ctx = TokenSelectionContext(tokenIndex: mergedSemanticIndex, range: union, surface: surface, semanticSpan: semantic, sourceSpanIndices: semantic.sourceSpanIndices, annotatedSpan: ephemeral)
        tokenSelection = ctx

        // Keep the Extract Words sheet's in-sheet dictionary panel in sync.
        if wasShowingTokensPopover {
            sheetSelection = ctx
        }
        if sheetDictionaryPanelEnabled {
            sheetSelection = ctx
            // If the Extract Words sheet is open, do not present another sheet.
            if wasShowingTokensPopover == false {
                isDictionarySheetPresented = true
            }
        }
        showTokensPopover = wasShowingTokensPopover
    }

    func splitSelection(at offset: Int) {
        guard let selection = tokenSelection else { return }
        guard selection.range.length > 1 else { return }
        guard offset > 0, offset < selection.range.length else { return }

        let splitUTF16Index = selection.range.location + offset

        // Persist an explicit hard cut at the split boundary.
        // Rationale: even when Stage-1 spans are split, downstream semantic regrouping / tail-merge
        // passes may legally merge adjacent semantic spans back together unless a hard boundary
        // blocks it. This was surfacing as “split requires two attempts” because the second split
        // happens to fall on an existing Stage-1 boundary and records a hard cut.
        if propagateTokenEdits {
            var cuts: [Int] = [splitUTF16Index]
            cuts.append(contentsOf: splitHardCutCandidatesEverywhere(surface: selection.surface, offset: offset))
            tokenBoundaries.addHardCuts(noteID: activeNoteID, utf16Indices: cuts, text: inputText)
        } else {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
        }

        // Keep the dictionary panel updated after the split by restoring selection to one of the
        // resulting token ranges (smallest side; tie-break to the right).
        let baseRange = selection.range
        if baseRange.location != NSNotFound, baseRange.length > 1 {
            let baseStart = baseRange.location
            let baseEnd = NSMaxRange(baseRange)
            let leftLen = splitUTF16Index - baseStart
            let rightLen = baseEnd - splitUTF16Index
            if leftLen > 0, rightLen > 0 {
                let leftRange = NSRange(location: baseStart, length: leftLen)
                let rightRange = NSRange(location: splitUTF16Index, length: rightLen)
                let target = (rightLen <= leftLen) ? rightRange : leftRange
                pendingSelectionRange = target
                persistentSelectionRange = target
            }
        }

        // Clear the current selection now (it may no longer correspond to a single token), but
        // keep `pendingSelectionRange` so we can restore after recompute.
        tokenSelection = nil
        if sheetDictionaryPanelEnabled || showTokensPopover {
            sheetSelection = nil
        }
        pendingSplitFocusSelectionID = nil

        // If the split creates a 1-character prefix/suffix, explicitly lock the *outer* edge too.
        // Otherwise Stage-2.5 may legitimately regroup that 1-char token into its neighbor
        // (e.g. splitting “…か” right before “ら” can immediately become “から”).
        let selectionStart = selection.range.location
        let selectionEnd = NSMaxRange(selection.range)
        let leftLen = splitUTF16Index - selectionStart
        let rightLen = selectionEnd - splitUTF16Index
        if leftLen == 1 {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: selectionStart, text: inputText)
        }
        if rightLen == 1 {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: selectionEnd, text: inputText)
        }
        guard let stage1 = furiganaSpans else { return }

        let indices = selection.sourceSpanIndices
        let group: ArraySlice<AnnotatedSpan>
        if indices.lowerBound >= 0, indices.upperBound <= stage1.count {
            group = stage1[indices.lowerBound..<indices.upperBound]
        } else {
            group = []
        }

        let stage1Index: Int? = {
            if let local = group.enumerated().first(where: { NSLocationInRange(splitUTF16Index, $0.element.span.range) })?.offset {
                return indices.lowerBound + local
            }
            return stage1.enumerated().first(where: { NSLocationInRange(splitUTF16Index, $0.element.span.range) })?.offset
        }()

        // If the requested split falls exactly on an existing Stage-1 boundary, we can't split
        // inside a span. Instead, record an explicit non-crossable cut so Stage-2.5 won't merge
        // across it.
        if stage1Index == nil {
            // (Should be rare because the search above typically finds a containing span.)
            if propagateTokenEdits {
                applyHardCutEverywhere(splitUTF16Index: splitUTF16Index)
            } else {
                tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            }
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            return
        }

        guard let spanIndex = stage1Index, stage1.indices.contains(spanIndex) else { return }
        let spanRange = stage1[spanIndex].span.range
        let localOffset = splitUTF16Index - spanRange.location

        if localOffset <= 0 || localOffset >= spanRange.length {
            if propagateTokenEdits {
                applyHardCutEverywhere(splitUTF16Index: splitUTF16Index)
            } else {
                tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            }
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            return
        }

        if propagateTokenEdits {
            applySpanSplitEverywhere(range: spanRange, offset: localOffset, actionName: "Split Token")
        } else {
            applySpanSplit(spanIndex: spanIndex, range: spanRange, offset: localOffset, actionName: "Split Token")
        }
    }

    func splitHardCutCandidatesEverywhere(surface: String, offset: Int) -> [Int] {
        let nsText = inputText as NSString
        guard nsText.length > 0 else { return [] }
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSurface.isEmpty == false else { return [] }
        guard offset > 0 else { return [] }

        var out: [Int] = []
        out.reserveCapacity(32)

        var search = NSRange(location: 0, length: nsText.length)
        while search.length > 0 {
            let found = nsText.range(of: normalizedSurface, options: [], range: search)
            if found.location == NSNotFound { break }

            let cut = found.location + offset
            if cut > found.location, cut < NSMaxRange(found), cut > 0, cut < nsText.length {
                out.append(cut)
            }

            let next = found.location + max(1, found.length)
            guard next < nsText.length else { break }
            search = NSRange(location: next, length: nsText.length - next)
        }

        return out
    }

    func applySpanMergeEverywhere(mergeRange: Range<Int>, actionName: String) -> NSRange? {
        guard let spans = furiganaSpans else { return nil }
        guard mergeRange.count >= 2 else { return nil }
        guard mergeRange.lowerBound >= 0, mergeRange.upperBound <= spans.count else { return nil }

        let baseSpans = spans.map(\.span)
        let pattern: [String] = mergeRange.map { baseSpans[$0].surface }
        guard pattern.isEmpty == false else { return nil }

        // Selected union (used to keep selection stable).
        var selectedUnion = baseSpans[mergeRange.lowerBound].range
        for i in mergeRange.dropFirst() {
            selectedUnion = NSUnionRange(selectedUnion, baseSpans[i].range)
        }

        let nsText = inputText as NSString
        guard selectedUnion.location != NSNotFound, selectedUnion.length > 0 else { return nil }
        guard NSMaxRange(selectedUnion) <= nsText.length else { return nil }

        func matches(at i: Int) -> Bool {
            guard i >= 0 else { return false }
            guard i + pattern.count <= baseSpans.count else { return false }
            for j in 0..<pattern.count {
                let a = baseSpans[i + j]
                if a.surface != pattern[j] { return false }
                if j > 0 {
                    let prev = baseSpans[i + j - 1]
                    if NSMaxRange(prev.range) != a.range.location { return false }
                }
            }
            return true
        }

        var newSpans: [TextSpan] = []
        newSpans.reserveCapacity(baseSpans.count)

        var i = 0
        while i < baseSpans.count {
            if matches(at: i) {
                var union = baseSpans[i].range
                for j in 1..<pattern.count {
                    union = NSUnionRange(union, baseSpans[i + j].range)
                }
                if union.location != NSNotFound, union.length > 0, NSMaxRange(union) <= nsText.length {
                    let mergedSurface = nsText.substring(with: union)
                    newSpans.append(TextSpan(range: union, surface: mergedSurface, isLexiconMatch: false))
                    i += pattern.count
                    continue
                }
            }

            newSpans.append(baseSpans[i])
            i += 1
        }

        replaceSpans(newSpans, actionName: actionName)
        return selectedUnion
    }

    func applySpanSplitEverywhere(range: NSRange, offset: Int, actionName: String) {
        guard let spans = furiganaSpans else { return }
        guard range.length > 1 else { return }
        guard offset > 0, offset < range.length else { return }

        let nsText = inputText as NSString
        guard nsText.length > 0 else { return }
        guard NSMaxRange(range) <= nsText.length else { return }

        let targetSurface = nsText.substring(with: range)
        guard targetSurface.isEmpty == false else { return }

        let baseSpans = spans.map(\.span)
        var newSpans: [TextSpan] = []
        newSpans.reserveCapacity(baseSpans.count + 16)

        for span in baseSpans {
            if span.surface == targetSurface, span.range.length > 1, offset > 0, offset < span.range.length {
                let leftRange = NSRange(location: span.range.location, length: offset)
                let rightRange = NSRange(location: span.range.location + offset, length: span.range.length - offset)
                if leftRange.length > 0, rightRange.length > 0, NSMaxRange(rightRange) <= nsText.length {
                    let leftSurface = nsText.substring(with: leftRange)
                    let rightSurface = nsText.substring(with: rightRange)
                    newSpans.append(TextSpan(range: leftRange, surface: leftSurface, isLexiconMatch: false))
                    newSpans.append(TextSpan(range: rightRange, surface: rightSurface, isLexiconMatch: false))
                    continue
                }
            }
            newSpans.append(span)
        }

        replaceSpans(newSpans, actionName: actionName)
    }

    func applyHardCutEverywhere(splitUTF16Index: Int) {
        let noteID = activeNoteID
        let text = inputText
        guard let spans = furiganaSpans?.map(\.span), spans.isEmpty == false else {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
            return
        }

        // Identify the boundary's left/right token surfaces.
        var leftSurface: String? = nil
        var rightSurface: String? = nil
        for i in 0..<(spans.count - 1) {
            let a = spans[i]
            let b = spans[i + 1]
            if NSMaxRange(a.range) == splitUTF16Index, b.range.location == splitUTF16Index {
                leftSurface = a.surface
                rightSurface = b.surface
                break
            }
        }

        guard let leftSurface, let rightSurface else {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
            return
        }

        var indices: [Int] = []
        indices.reserveCapacity(32)
        for i in 0..<(spans.count - 1) {
            let a = spans[i]
            let b = spans[i + 1]
            guard a.surface == leftSurface, b.surface == rightSurface else { continue }
            let boundary = NSMaxRange(a.range)
            guard boundary == b.range.location else { continue }
            indices.append(boundary)
        }

        if indices.isEmpty {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
        } else {
            tokenBoundaries.addHardCuts(noteID: noteID, utf16Indices: indices, text: text)
        }
    }

    func resetSelectionOverrides() {
        guard let selection = tokenSelection else { return }

        let noteID = activeNoteID
        let selectionStart = selection.range.location
        let selectionEnd = NSMaxRange(selection.range)

        let boundariesToReset: [Int] = {
            var indices: [Int] = [selectionStart, selectionEnd]
            let spacing = tokenBoundaries.interTokenSpacing(for: noteID, text: inputText)
            if spacing.isEmpty == false {
                indices.append(contentsOf: spacing.keys.filter { $0 >= selectionStart && $0 <= selectionEnd })
            }
            return Array(Set(indices))
        }()

        tokenBoundaries.resetInterTokenSpacing(noteID: noteID, boundaryUTF16Indices: boundariesToReset)

        applyOverridesChange(range: selection.range, newOverrides: [], actionName: "Reset Token")
        resetSpanEdits(in: selection.range, actionName: "Reset Token")
        clearSelection(resetPersistent: false)
    }

    func resetAllCustomSpans() {
        let noteID = activeNoteID
        let previousAllOverrides = readingOverrides.allOverrides()
        let previousSpanSnapshot = tokenBoundaries.snapshot(for: noteID)

        readingOverrides.removeAll(for: noteID)
        tokenBoundaries.removeAll(for: noteID)
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        clearSelection()
        triggerFuriganaRefreshIfNeeded(reason: "reset all overrides", recomputeSpans: true)

        registerResetAllUndo(previousAllOverrides: previousAllOverrides, previousSpanSnapshot: previousSpanSnapshot, noteID: noteID)
    }

    func applySpanMerge(mergeRange: Range<Int>, actionName: String) -> NSRange? {
        guard let spans = furiganaSpans else { return nil }
        guard mergeRange.count >= 2 else { return nil }
        guard mergeRange.lowerBound >= 0, mergeRange.upperBound <= spans.count else { return nil }

        var union = spans[mergeRange.lowerBound].span.range
        for i in mergeRange.dropFirst() {
            union = NSUnionRange(union, spans[i].span.range)
        }

        let nsText = inputText as NSString
        guard union.location != NSNotFound, union.length > 0 else { return nil }
        guard NSMaxRange(union) <= nsText.length else { return nil }
        let mergedSurface = nsText.substring(with: union)

        var newSpans = spans.map(\.span)
        newSpans.removeSubrange(mergeRange)
        newSpans.insert(TextSpan(range: union, surface: mergedSurface, isLexiconMatch: false), at: mergeRange.lowerBound)

        replaceSpans(newSpans, actionName: actionName)
        return union
    }

    func applySpanSplit(spanIndex: Int, range: NSRange, offset: Int, actionName: String) {
        guard let spans = furiganaSpans else { return }
        guard spans.indices.contains(spanIndex) else { return }
        guard range.length > 1 else { return }
        guard offset > 0, offset < range.length else { return }

        let leftRange = NSRange(location: range.location, length: offset)
        let rightRange = NSRange(location: range.location + offset, length: range.length - offset)
        let nsText = inputText as NSString
        guard NSMaxRange(rightRange) <= nsText.length else { return }

        let leftSurface = nsText.substring(with: leftRange)
        let rightSurface = nsText.substring(with: rightRange)

        var newSpans = spans.map(\.span)
        newSpans.remove(at: spanIndex)
        newSpans.insert(TextSpan(range: rightRange, surface: rightSurface, isLexiconMatch: false), at: spanIndex)
        newSpans.insert(TextSpan(range: leftRange, surface: leftSurface, isLexiconMatch: false), at: spanIndex)
        replaceSpans(newSpans, actionName: actionName)
    }

    func resetSpanEdits(in range: NSRange, actionName: String) {
        guard inputText.isEmpty == false else { return }
        let noteID = activeNoteID
        guard tokenBoundaries.hasCustomSpans(for: noteID) else { return }
        let text = inputText
        let previousSnapshot = tokenBoundaries.snapshot(for: noteID)
        registerSpanUndo(previousSnapshot: previousSnapshot, noteID: noteID, actionName: actionName)

        Task {
            do {
                let base = try await SegmentationService.shared.segment(text: text)
                let replacement = base.filter { NSIntersectionRange($0.range, range).length > 0 }
                await MainActor.run {
                    replaceSpans(in: range, with: replacement, actionName: actionName)
                }
            } catch {
                return
            }
        }
    }

    func replaceSpans(_ spans: [TextSpan], actionName: String) {
        let noteID = activeNoteID
        let previousSnapshot = tokenBoundaries.snapshot(for: noteID)
        registerSpanUndo(previousSnapshot: previousSnapshot, noteID: noteID, actionName: actionName)
        tokenBoundaries.setSpans(noteID: noteID, spans: spans, text: inputText)
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: actionName, recomputeSpans: true)
    }

    func replaceSpans(in range: NSRange, with replacement: [TextSpan], actionName: String) {
        let noteID = activeNoteID
        let text = inputText
        var base = tokenBoundaries.spans(for: noteID, text: text) ?? furiganaSpans?.map(\.span) ?? []
        base.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        base.append(contentsOf: replacement)
        base.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location { return lhs.range.length < rhs.range.length }
            return lhs.range.location < rhs.range.location
        }
        tokenBoundaries.setSpans(noteID: noteID, spans: base, text: text)
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: actionName, recomputeSpans: true)
    }

    func registerSpanUndo(previousSnapshot: [TokenBoundariesStore.StoredSpan]?, noteID: UUID, actionName: String) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            tokenBoundaries.restore(noteID: noteID, snapshot: previousSnapshot)
            updateCustomizedRanges()
            triggerFuriganaRefreshIfNeeded(reason: "undo: \(actionName)", recomputeSpans: true)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName(actionName)
    }

    func registerResetAllUndo(previousAllOverrides: [ReadingOverride], previousSpanSnapshot: [TokenBoundariesStore.StoredSpan]?, noteID: UUID) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            readingOverrides.replaceAll(with: previousAllOverrides)
            tokenBoundaries.restore(noteID: noteID, snapshot: previousSpanSnapshot)
            overrideSignature = computeOverrideSignature()
            updateCustomizedRanges()
            triggerFuriganaRefreshIfNeeded(reason: "undo: reset all", recomputeSpans: true)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName("Reset All")
    }

    func applyOverridesChange(removing ranges: [NSRange], adding newOverrides: [ReadingOverride], actionName: String) {
        let noteID = activeNoteID
        let previous = readingOverrides.overrides(for: noteID).filter { existing in
            ranges.contains { existing.overlaps($0) }
        }
        let rangeSummary: String = {
            if ranges.count == 1 {
                let r = ranges[0]
                return "\(r.location)-\(NSMaxRange(r))"
            }
            return "count=\(ranges.count)"
        }()
        CustomLogger.shared.debug("Applying overrides action=\(actionName) note=\(noteID) ranges=\(rangeSummary) replacing=\(previous.count) inserting=\(newOverrides.count)")

        readingOverrides.apply(noteID: noteID, removing: ranges, adding: newOverrides)
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: "manual token override", recomputeSpans: true)
        registerUndo(previousOverrides: previous, ranges: ranges, actionName: actionName)
    }

    func applyOverridesChange(range: NSRange, newOverrides: [ReadingOverride], actionName: String) {
        applyOverridesChange(removing: [range], adding: newOverrides, actionName: actionName)
    }

    func registerUndo(previousOverrides: [ReadingOverride], ranges: [NSRange], actionName: String) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            applyOverridesChange(removing: ranges, adding: previousOverrides, actionName: actionName)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName(actionName)
    }

    func canMergeSelection(_ direction: MergeDirection) -> Bool {
        guard let selection = tokenSelection else { return false }
        return stage1MergeRange(forSemanticIndex: selection.tokenIndex, direction: direction) != nil
    }

    func stage1MergeRange(forSemanticIndex index: Int, direction: MergeDirection) -> Range<Int>? {
        guard let stage1 = furiganaSpans else { return nil }
        guard furiganaSemanticSpans.indices.contains(index) else { return nil }
        let semantic = furiganaSemanticSpans[index]

        let lower = semantic.sourceSpanIndices.lowerBound
        let upper = semantic.sourceSpanIndices.upperBound
        guard lower >= 0, upper <= stage1.count else { return nil }

        switch direction {
        case .previous:
            let neighbor = lower - 1
            guard stage1.indices.contains(neighbor) else { return nil }
            return neighbor..<upper
        case .next:
            let neighbor = upper
            guard stage1.indices.contains(neighbor) else { return nil }
            return lower..<(neighbor + 1)
        }
    }

    func selectionIsCustomized(_ selection: TokenSelectionContext) -> Bool {
        if customizedRanges.contains(where: { NSIntersectionRange($0, selection.range).length > 0 }) {
            return true
        }

        let noteID = activeNoteID
        let start = selection.range.location
        let end = NSMaxRange(selection.range)
        let spacing = tokenBoundaries.interTokenSpacing(for: noteID, text: inputText)
        return spacing.keys.contains { $0 >= start && $0 <= end }
    }

    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
    }
}
