; Help pages (filetype `help`): headings below a `===` rule, below a `---`
; rule, and UPPERCASE headings, nested in that order
((h1 (heading) @section.name @section)
 (#set! type "header")
 (#set! level "1"))

((h2 (heading) @section.name @section)
 (#set! type "header")
 (#set! level "2"))

((h3 (heading) @section.name @section)
 (#set! type "header")
 (#set! level "3"))
