# Backlog

## Release goals linkage
- Before closing an iteration, review `docs/ReleaseGoals.md` and mark each goal as Done, Deferred, or Won’t fix.
- When deferring backlog items, note the rationale alongside the release goal.

## Known bugs
- [x] wrapping for long lines just cuts off all text below the first line
- [x] toggling view/edit mode shouldn't jump scroll back to the top
- [x] disable text selection in view mode
- [ ] disable confirmation dialog for note deletion

## Performance / UX issues
- [x] Animation on cards tab not great
- [x] Toggling furigana shouldn’t jump scroll back to top
- [x] When a word only has one definition, don’t show the arrows on either side or the 1/1
- [x] hide merge/split buttons behind a toggle

## Furigana / tokenization issues
- [ ] Bring back longest run search
- [x] わ sometimes shows up as the furigana for 私 in 私たち, when it should be わたし
- [ ] なり + たく + て should be one unit. why is it not treated as a string?
- [x] despite being registered as separate tokens, であ shows up over the middle of 出 and 逢. って is yet another token. it should just be 出逢って. the furigana is correct in this case but seems like it shouldn't be given the segmentation
- [ ] 光ってる shows up as two tokens, 光って and る
- [ ] 出そうになる shows up as 出そ+うに+なる instead of 出そう+に+なる

## Dictionary issues
- [x] Need a useful dictionary page for words
- [x] When a page is saved Kanji, don’t show entries of other kanji with the same pronunciation 
- [x] Words need a reference to the note they’re saved from
- [x] Words can also optionally be added to custom lists

## Ideas
- [ ] add a toggle for highlighting distinct parts of speech
- [ ] add a toggle for distinguishing kanji, hiragana and katakana
- [ ] quiz on next and previous lines 
