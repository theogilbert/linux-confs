; A section is a banner block comment; only the first inner line is the name:
;   /******************
;    * section name   *
;    * section desc   *
;    ******************/
((comment) @section @section.name
 (#lua-match? @section "^/%*%*+%s*\n")
 (#lua-match? @section "\n%s*%*+/$")
 (#gsub! @section.name "^/%*+%s*\n%s*%*%s*(.-)%s*%**%s*\n.*$" "%1")
 (#set! type "header")
 (#set! level "1")
 )

; The same banner as `//` comments:
;   //////////////////
;   // section name //
;   // section desc //
;   //////////////////
((comment) @section
 .
 (comment) @section.name
 (#sections-banner? @section @section.name)
 (#lua-match? @section "^///+$")
 (#lua-match? @section.name "^//%s.*%s//$")
 (#gsub! @section.name "^//%s*(.-)%s*//$" "%1")
 (#set! type "header")
 (#set! level "1")
 )

; A subsection is a single comment whose `#` count is its level:
;   // ## subsection
((comment) @section @section.name @section.level
 (#lua-match? @section "^//%s*##+%s+%S")
 (#gsub! @section.name "^//%s*#+%s+(.-)%s*$" "%1")
 (#gsub! @section.level "^//%s*(#+).*$" "%1")
 (#set! type "header")
 )
