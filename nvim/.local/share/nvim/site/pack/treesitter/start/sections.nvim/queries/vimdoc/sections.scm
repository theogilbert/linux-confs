; Help pages (filetype `help`): headings below a `===` rule, below a `---`
; rule, and UPPERCASE headings, nested in that order. The modeline closing a
; page right below a rule is not a heading.
((h1 (heading) @section.name @section)
 (#not-lua-match? @section.name "^vim:")
 (#set! type "header")
 (#set! level "1"))

((h2 (heading) @section.name @section)
 (#not-lua-match? @section.name "^vim:")
 (#set! type "header")
 (#set! level "2"))

((h3 (heading) @section.name @section)
 (#set! type "header")
 (#set! level "3"))

; Tagged entries, nested under headings: a paragraph opening with a line
; ending with tags, e.g. `nvim_buf_attach({buf})  *nvim_buf_attach()*`...
(block
 .
 (line . (_) @first (tag) .) @section @section.name
 (#not-lua-match? @first "^%*")
 (#gsub! @section.name "%s*%*[^%s*]+%*" "")
 (#gsub! @section.name "%s+" " ")
 (#gsub! @section.name "^ ?(.-) ?$" "%1")
 (#set! type "header")
 (#set! level "4"))

; ...or by a line of tags only, e.g. `*'aleph'* *'al'*`, tagging the line below
; it, itself followed by an indented body (as opposed to a tagged paragraph).
; A line opening a code block spans the whole block, so must hold a single row.
(block
 .
 (line) @tags
 .
 (line . (_) @first) @section @section.name
 .
 (line) @body
 (#sections-tags-only? @tags)
 (#not-sections-indented? @section)
 (#sections-indented? @body)
 (#not-lua-match? @first "^%*")
 (#not-lua-match? @section.name "~%s*$")
 (#not-lua-match? @section.name "\n.")
 (#gsub! @section.name "%s*%*[^%s*]+%*" "")
 (#gsub! @section.name "%s+" " ")
 (#gsub! @section.name "^ ?(.-) ?$" "%1")
 (#set! type "header")
 (#set! level "4"))

; ...or by a line of tags only above an indented body, named by its tags, e.g.
; `*sections.setup({config})*`
(block
 .
 (line) @section @section.name
 .
 (line) @body
 (#sections-tags-only? @section)
 (#sections-indented? @body)
 (#gsub! @section.name "%*" "")
 (#gsub! @section.name "%s+" " ")
 (#gsub! @section.name "^ ?(.-) ?$" "%1")
 (#set! type "header")
 (#set! level "4"))

; Column headings, e.g. `Parameters: ~`, nested under entries and headings
((column_heading (heading) @section.name) @section
 (#gsub! @section.name ":$" "")
 (#gsub! @section.name "%s+" " ")
 (#set! type "header")
 (#set! level "5"))

; The parser requires a space before the `~` of a column heading, which help
; pages commonly omit, e.g. `Options:~`. A line opening a code block spans the
; whole block, so must hold a single row.
(block
 (line . (_) @first) @section @section.name
 (#not-lua-match? @first "^%*")
 (#not-lua-match? @section.name "\n.")
 (#lua-match? @section.name "[^%s~]~%s*$")
 (#gsub! @section.name ":?~%s*$" "")
 (#gsub! @section.name "%s+" " ")
 (#gsub! @section.name "^ ?(.-) ?$" "%1")
 (#set! type "header")
 (#set! level "5"))
