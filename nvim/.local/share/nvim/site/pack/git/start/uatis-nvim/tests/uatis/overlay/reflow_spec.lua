-- A reformat that moves code across line breaks. A line diff can only
-- say "this line became those lines", and should say exactly that; a
-- structural diff knows the code did not change and should say nothing.
local h = require("helpers")

local old = [[
  class S3Driver:
      @classmethod
      async def create(cls, params: dict[str, Any], settings: DriverSettings) -> "S3Driver":
          return cls()

      def close(self):
          self._closed = True
]]
local new = [[
  class S3Driver:
      @classmethod
      async def create(
          cls, params: dict[str, Any], settings: DriverSettings
      ) -> "S3Driver":
          return cls()

      def close(self):
          self._shutdown = True
]]

describe("reflow", function()
  -- The real edit further down is a 1:1 pair, so it still gets characters.
  it("is the line it replaced, then three added lines, in line mode", function()
    h.drawn({ backend = "line", lang = "python", old = old, new = new }, [[
      | class S3Driver:
      |     @classmethod
      -     async def create(cls, params: dict[str, Any], settings: DriverSettings) -> "S3Driver":
      +     async def create(
      +         cls, params: dict[str, Any], settings: DriverSettings
      +     ) -> "S3Driver":
      |         return cls()
      |
      |     def close(self):
      - ⟨        self.⟩_closed⟨ = True⟩
      |         self.⟦_shutdown⟧ = True
    ]])
  end)

  it("is nothing at all structurally, beside the real edit", function()
    if not h.difft then
      return pending("difftastic is not installed")
    end
    h.drawn({ lang = "python", old = old, new = new }, [[
      | class S3Driver:
      |     @classmethod
      |     async def create(
      |         cls, params: dict[str, Any], settings: DriverSettings
      |     ) -> "S3Driver":
      |         return cls()
      |
      |     def close(self):
      - ⟨        self.⟩_closed⟨ = True⟩
      |         self.⟦_shutdown⟧ = True
    ]])
  end)
end)
