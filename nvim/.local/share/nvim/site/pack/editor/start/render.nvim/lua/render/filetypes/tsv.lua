-- A tab-separated file, as the table it is: the csv reader, told the
-- delimiter rather than left to guess it.
return require("render.filetypes.csv").reader("\t")
