-- Mapping lifecycle: keys lent to a buffer and given back. Lives in
-- common.nvim (common.keys); this name stays for the modules here.
--
-- The side pane's buffer is a scratch one, created and thrown away with
-- the pane, so nothing pre-existing is at risk there. The diff view is a
-- different matter: it maps over a buffer you are working in, and the
-- pane lends its own keys to buffers it does not own -- both have to
-- leave them exactly as they were found.
return require("common.keys")
