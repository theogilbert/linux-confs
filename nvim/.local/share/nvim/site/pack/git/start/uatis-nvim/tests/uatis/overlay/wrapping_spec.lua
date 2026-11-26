-- Wrapping an expression moves code without deleting any of it. Paired
-- by position anyway, the tail of each line read as removed and left a
-- before-image of red fragments over dimmed context, unreadable as the
-- code that was there. (`content_survives` itself is in diff_spec.lua.)
local h = require("helpers")

local function drawn(old, new, expected, backend)
  h.drawn({ lang = "python", old = old, new = new, backend = backend }, expected)
end

local call = '        region = self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")'
local flat = "class S3:\n    def region_for(self, bucket):\n" .. call .. "\n        return region"
local wrapped = "class S3:\n    def region_for(self, bucket):\n        region = (\n    "
  .. call .. "\n        )\n        return region"

describe("wrapping", function()
  it("is still stated as a substitution in line mode, the old line whole", function()
    drawn(flat, wrapped, [[
      | class S3:
      |     def region_for(self, bucket):
      -         region = self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")
      +         region = (
      +             region = self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")
      +         )
      |         return region
    ]], "line")
  end)
end)

describe("wrapping, structurally", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  it("shows no before-image for a pure wrap", function()
    drawn(flat, wrapped, [[
      | class S3:
      |     def region_for(self, bucket):
      ~         region = ⟦(⟧
      ~         ⟦    region = ⟧self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")
      +         )
      |         return region
    ]])
  end)

  -- The old first line ends mid-call: the shape that once produced a full
  -- red copy of code still sitting two rows below it.
  it("shows none when the call it wraps already spanned lines", function()
    drawn([[
      class S3:
          def region_for(self, bucket):
              region = self._client.get_bucket_location(Bucket=bucket).get(
                  "LocationConstraint"
              )
              return region
    ]], [[
      class S3:
          def region_for(self, bucket):
              region = (
                  self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")
              )
              return region
    ]], [[
      | class S3:
      |     def region_for(self, bucket):
      |         region = ⟦(⟧
      |             self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")
      |         )
      |         return region
    ]])
  end)

  -- Not compared line by position: the content shifts down a line. And
  -- not dimmed into fragments: all difftastic reports gone from those
  -- rows is a bracket and two commas.
  it("shows a real edit keeping the line count as the whole old block", function()
    drawn([[
      class S3:
          def f(self, b):
              region = self._client.get_bucket_location(Bucket=b).get(
                  "LocationConstraint",
                  "us-east-1",
              )
              return region
    ]], [[
      class S3:
          def f(self, b):
              region = (
                  self._client.get_bucket_location(Bucket=b).get("LocationConstraint")
                  or "us-east-1"
              )
              return region
    ]], [[
      | class S3:
      |     def f(self, b):
      -         region = self._client.get_bucket_location(Bucket=b).get(
      -             "LocationConstraint",
      -             "us-east-1",
      -         )
      |         region = ⟦(⟧
      |             self._client.get_bucket_location(Bucket=b).get⟦(⟧"LocationConstraint"⟦)⟧
      |             ⟦or⟧ "us-east-1"
      |         )
      |         return region
    ]])
  end)

  -- ...but where NAMES went, saying which is the whole point: the old
  -- line reads through, dimmed, the words that went at full strength --
  -- the statement the side-by-side window makes, from the same spans.
  it("steps a renamed call's old line back around the names that went", function()
    drawn("class D:\n    def go(self, sql, binds):\n        cur = self._conn.execute(sql, binds)",
      "class D:\n    def go(self, sql, binds):\n        cur = self._sql(sql, binds, private=True)",
      [[
        | class D:
        |     def go(self, sql, binds):
        - ⟨        cur = self⟩._conn.execute⟨(sql, binds)⟩
        |         cur = self.⟦_sql⟧(sql, binds⟦, private=True⟧)
      ]])
  end)

  -- difftastic splits the reflow into a 1:1 replacement and an insertion
  -- below it, so the surviving words are spread over rows the survival
  -- window does not reach. It reports no removal on that row, and that
  -- answer is the one that counts.
  it("removes nothing for an import list that gained a name and was reflowed", function()
    drawn([[
      from .drivers.base import BaseDriver, DriverSettings, ReadResult
      from .protocol import Connection
    ]], [[
      from .drivers.base import (
          BaseDriver,
          DriverSettings,
          FindNotSupported,
          ReadResult,
      )
      from .protocol import Connection
    ]], [[
      | from .drivers.base import ⟦(⟧
      |     BaseDriver,
      |     DriverSettings,
      +     FindNotSupported,
      |     ReadResult⟦,⟧
      + )
      | from .protocol import Connection
    ]])
  end)

  -- Its old tokens are all still there, spread across the added
  -- paragraph, wider than the survival test allows for a move.
  it("shows only the line a docstring that grew changed", function()
    drawn([[
      class C:
          def reset(self, path):
              """Clear cached results at or below path.

              Args:
                  path: Path prefix to reset. Entries whose keys start with it
                      are removed, along with any ancestor entries.
              """
              self._drop(path)
    ]], [[
      class C:
          def reset(self, path):
              """Clear cached results at or below path.

              Args:
                  path: Path prefix to reset. Entries whose keys start with it
                      are removed, along with any ancestor entries. Cached finds
                      are dropped in full whatever the path: they are keyed by
                      search, not by path, so a reset invalidates them both ways.
              """
              self._drop(path)
    ]], [[
      | class C:
      |     def reset(self, path):
      |         """Clear cached results at or below path.
      |
      |         Args:
      |             path: Path prefix to reset. Entries whose keys start with it
      - ⟨                are removed, along with any ancestor entries.⟩
      ~                 are removed, along with any ancestor entries.⟦ Cached finds⟧
      +                 are dropped in full whatever the path: they are keyed by
      +                 search, not by path, so a reset invalidates them both ways.
      |         """
      |         self._drop(path)
    ]])
  end)
end)
