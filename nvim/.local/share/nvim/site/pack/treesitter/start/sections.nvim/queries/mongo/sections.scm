; A section is a banner block comment; only the first inner line is the name:
;   /******************
;    * section name   *
;    * section desc   *
;    ******************/
((comment) @section @section.name @section.description
 (#lua-match? @section "^/%*%*+%s*\n")
 (#lua-match? @section "\n%s*%*+/$")
 (#gsub! @section.name "^/%*+%s*\n%s*%*%s*(.-)%s*%**%s*\n.*$" "%1")
 (#gsub! @section.description "^/%*+%s*\n[^\n]*\n?(.-)%s*%*+/$" "%1")
 (#gsub! @section.description "^[ \t]*%*?[ \t]?" "")
 (#gsub! @section.description "\n[ \t]*%*?[ \t]?" "\n")
 (#gsub! @section.description "[ \t]+%*+[ \t]*\n" "\n")
 (#gsub! @section.description "[ \t]+%*+[ \t]*$" "")
 (#set! type "header")
 (#set! description_prefix "^//%s?")
 (#set! level "1")
 )

; A section is a name line between two rule lines; the name may be boxed:
;   //////////////////
;   // section name
;   //////////////////
;   // optional description, below the banner
((comment) @section
 .
 (comment) @section.name
 .
 (comment) @_close
 (#sections-banner? @section @section.name @_close)
 (#lua-match? @section "^///+$")
 (#lua-match? @_close "^///+$")
 (#lua-match? @section.name "^//%s*%S")
 (#not-lua-match? @section.name "^///+$")
 (#gsub! @section.name "^//%s*" "")
 (#gsub! @section.name "%s+//+%s*$" "")
 (#gsub! @section.name "%s+$" "")
 (#set! type "header")
 (#set! description_prefix "^//%s?")
 (#set! level "1")
 )

; A heading is a comment alone on its line, starting with `#`: its `#` count
; is its level, as for Markdown headers. Level 1 headings are banners' peers:
;   // # heading
;   // ## subheading
((comment) @section @section.name @section.level
 (#lua-match? @section "^//%s*#+%s+%S")
 (#sections-own-line? @section)
 (#gsub! @section.name "^//%s*#+%s+(.-)%s*$" "%1")
 (#gsub! @section.level "^//%s*(#+).*$" "%1")
 (#set! type "header")
 (#set! description_prefix "^//%s?")
 )
