# Backlog

This file is intentionally informal: quick notes, known bugs, and ideas.

## Known bugs
- wrapping for long lines just cuts off all text below the first line

## Performance / UX issues
- (add items)

## Furigana / tokenization issues
- わ sometimes shows up as the furigana for 私 in 私たち, when it should be わたし
- なり + たく + て should be one unit. why is it not treated as a string?
- despite being registered as separate tokens, であ shows up over the middle of 出 and 逢. って is yet another token. it should just be 出逢って
- 光ってる shows up as two tokens, 光って and る
- 出そうになる shows up as 出そ+うに+なる instead of 出そう+に+なる

## Dictionary issues
- (add items)

## Ideas
+ add a toggle for highlighting distinct parts of speech
+ add a toggle for distinguishing kanji, hiragana and katakana
