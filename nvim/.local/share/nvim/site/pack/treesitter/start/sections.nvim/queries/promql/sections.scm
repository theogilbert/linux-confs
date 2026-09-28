; A section is a banner of `#` comments; only the first inner line is the name:
;   ##################
;   # section name   #
;   # section desc   #
;   ##################
((comment) @section
 .
 (comment) @section.name
 (#match? @section "^###+$")
 (#match? @section.name "^# .* #$")
 (#gsub! @section.name "^#%s*(.-)%s*#$" "%1")
 (#set! type "header")
 )
