; A section is a banner of `--` comments; only the first inner line is the name:
;   ------------------
;   -- section name --
;   -- section desc --
;   ------------------
((comment) @section
 .
 (comment) @section.name
 (#sections-banner? @section @section.name)
 (#match? @section "^---+$")
 (#match? @section.name "^-- .* --$")
 (#gsub! @section.name "^%-%-%s*(.-)%s*%-%-$" "%1")
 (#set! type "header")
 (#set! level "1")
 )

; The same banner as a block comment:
;   /******************
;    * section name   *
;    * section desc   *
;    ******************/
((block_comment) @section @section.name
 (#lua-match? @section "^/%*%*+%s*\n")
 (#lua-match? @section "\n%s*%*+/$")
 (#gsub! @section.name "^/%*+%s*\n%s*%*%s*(.-)%s*%**%s*\n.*$" "%1")
 (#set! type "header")
 (#set! level "1")
 )

; A subsection is a single comment whose `#` count is its level:
;   -- ## subsection
((comment) @section @section.name @section.level
 (#lua-match? @section "^%-%-%s*##+%s+%S")
 (#gsub! @section.name "^%-%-%s*#+%s+(.-)%s*$" "%1")
 (#gsub! @section.level "^%-%-%s*(#+).*$" "%1")
 (#set! type "header")
 )
