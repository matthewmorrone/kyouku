# Backlog

## Known bugs
- [ ] wrapping for long lines just cuts off all text below the first line
- [ ] Bring back longest run search
- [ ] toggling view/edit mode shouldn't jump scroll back to the top
- [ ] disable text selection in view mode
- [ ] disable confirmation dialog for note deletion

## Performance / UX issues
- [ ] Animation on cards tab not great
- [ ] Toggling furigana shouldn’t jump scroll back to top
- [ ] When a word only has one definition, don’t show the arrows on either side or the 1/1
- [ ] high merge/split buttons behind a toggle

## Furigana / tokenization issues
- [x] わ sometimes shows up as the furigana for 私 in 私たち, when it should be わたし
- [ ] なり + たく + て should be one unit. why is it not treated as a string?
- [ ] despite being registered as separate tokens, であ shows up over the middle of 出 and 逢. って is yet another token. it should just be 出逢って. the furigana is correct in this case but seems like it shouldn't be given the segmentation
- [ ] 光ってる shows up as two tokens, 光って and る
- [ ] 出そうになる shows up as 出そ+うに+なる instead of 出そう+に+なる

## Dictionary issues
- [ ] Need a useful dictionary page for words
- [ ] When a page is saved Kanji, don’t show entries of other kanji with the same pronunciation 
- [ ] Words need a reference to the note they’re saved from
- [ ] Words can also optionally be added to custom lists

## Ideas
- [ ] add a toggle for highlighting distinct parts of speech
- [ ] add a toggle for distinguishing kanji, hiragana and katakana
- [ ] Quiz on next and previous lines 
