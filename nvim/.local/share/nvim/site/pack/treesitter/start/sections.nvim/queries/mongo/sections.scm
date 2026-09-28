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
 )
