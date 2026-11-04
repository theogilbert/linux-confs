;; extends

; Hide the backslash of escapes (`snake\_case` reads as `snake_case`), as LSP
; hovers (e.g. ty's docstrings) escape markdown characters.  The bundled query
; only conceals backticks and emphasis markers.
((backslash_escape) @conceal
  (#offset! @conceal 0 0 0 -1)
  (#set! conceal ""))
