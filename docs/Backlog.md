# Backlog

## Known bugs
- [x] make the confirmation dialog for note deletion not be a popover, it's never in the right spot and the arrow points to the wrong place. also, make the "delete associated words" a checkbox within it that's defaulted to off
- [x] remove the "themes" button in the notes view
- [ ] looking up english words no longer works

## Dictionary issues
- [x] is it possible to auto switch to correct keyboard when available?
- [x] don't want "dictionary surface" on the new word screen
- [x] enter button on the new word screen should dismiss keyboard
- [x] on the word details page, entries that are "common" should all appear before those that are not
- [ ] wouldn't it make more sense if example sentences were grouped by meaning/sense used?
- [ ] when a token is made up of multiple parts, list parts 
- [ ] in the example sentences, the corresponding English word should be highlighted too
- [ ] leverage embeddings in deciding whether to include example sentences, shouldn’t just be by string matching 
- [ ] lots of redundancy on word detail view
- [ ] need to be able to delete lists (optionally leaving their cards alone or deleting them)
- [ ] kanaete: if entered as kana, shouldn’t show up twice in the popup where the kanji would be
- [ ] ability to click on words in the example sentences (use popovers first)
- [ ] deduplicate example sentences
- [ ] if a word belonged to a note and was deleted, when you add it back it's not attached to the note
- [ ] custom reading popup should be prefilled and set to japanese keyboard

## Performance / UX issues
- [ ] issues with jumpy dictionary popup in paste area
- [ ] Make saving to the words list more responsive 
- [ ] Clicking the star button doesn’t always trigger bookmarking, but the bookmark button always does

## Furigana / tokenization issues
- [ ] Bring back longest run search
- [ ] なり + たく + て should be one unit. why is it not treated as a string?
- [ ] 光ってる shows up as two tokens, 光って and る
- [ ] 出そうになる shows up as 出そ+うに+なる instead of 出そう+に+なる

## Ideas
- [ ] add option to change displayed font for Japanese
- [ ] add a toggle for distinguishing kanji, hiragana and katakana (maybe with font?)
- [ ] add a toggle for highlighting distinct parts of speech
- [ ] quiz on next and previous words/lines
