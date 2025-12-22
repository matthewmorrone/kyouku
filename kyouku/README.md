# Kyouku — Functional Specification & Architecture Document

## 1. Purpose

Kyouku is an iOS application for Japanese reading and vocabulary acquisition.  
It allows users to paste Japanese text, automatically parse it, save notes, inspect tokens with optional furigana, select vocabulary for long-term study, and reference definitions from a bundled JMdict database.

## 2. Core Features

### 2.1 Text Input & Parsing
- Paste button inserts clipboard text.
- Text automatically tokenizes using MeCab (IPADic).
- Tokens expose:
  - surface  
  - reading  
  - lemma  
  - part of speech  

### 2.2 Notes System
- Notes consist of:
  - ID  
  - Title (defaults to first line)  
  - Full multiline text (newlines preserved)  
  - Token list  
  - Creation date  
- Notes list view shows all saved notes.
- Selecting a note opens a full note detail page.

### 2.3 Token Display
- Tokens rendered with a reusable component.
- Furigana shown via custom RubyText.
- Global furigana toggle.
- Per-token furigana tap toggle.

### 2.4 Vocabulary List
- Words extracted from note tokens.
- Words include lemma, reading, pos, creation date, and sourceNote reference.
- Word list has delete support.

### 2.5 Dictionary Integration (SQLite JMdict)
- Bundled `dictionary.sqlite3` database.
- Lookup performed by lemma/reading/surface.
- Returns headword, reading, glosses.
- Used in Note Detail and Words views.

## 3. Architecture

### 3.1 Models
- `ParsedToken`
- `Note`
- `Word`
- `DictionaryEntry`

### 3.2 Stores
- `NotesStore`
- `WordStore`

### 3.3 Views
- `PasteView`
- `NotesView`
- `NoteDetailView`
- `WordsView`
- `TokenChip`
- `RubyText`

### 3.4 Parser
- `JapaneseParser` wrapping MeCab tokenizer.

### 3.5 Dictionary Engine
- SQLite-based queries.

## 4. Workflow

1. User pastes text.  
2. Automatic parsing occurs.  
3. User saves note.  
4. Notes are browsed & opened.  
5. Tokens can show dictionary info.  
6. User extracts words from tokens.  
7. Vocabulary list grows.  

