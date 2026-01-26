select glosses.entry_id, glosses.order_index, glosses.text, entries.is_common,  kanji.text, kana_forms.text from glosses 
inner join entries on entries.id = glosses.entry_id 
inner join kana_forms on entries.id = kana_forms.entry_id 
inner join kanji on entries.id = kanji.entry_id 
where glosses.text = "thing"
and kanji.is_common = 1
and kana_forms.is_common = 1
and entries.is_common = 1 
order by order_index, length(glosses.text);

select entries.id, kanji.text, kana_forms.text, entries.is_common, glosses.text, glosses.order_index, kana_forms.is_common from kanji 
inner join entries on entries.id = kanji.entry_id 
inner join glosses on entries.id = glosses.entry_id
inner join kana_forms on entries.id = kana_forms.entry_id
where kanji.text like '事'
and kanji.is_common = 1
and kana_forms.is_common = 1
and entries.is_common = 1 
order by order_index, length(glosses.text);

select entries.id, kanji.text, kana_forms.text, entries.is_common, glosses.text, glosses.order_index, kana_forms.is_common from kanji 
inner join entries on entries.id = kanji.entry_id 
inner join glosses on entries.id = glosses.entry_id
inner join kana_forms on entries.id = kana_forms.entry_id
where kana_forms.text like 'こと'
and kanji.is_common = 1
and kana_forms.is_common = 1
and entries.is_common = 1 
order by order_index, length(glosses.text);