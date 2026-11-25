local markdown = require("render.markdown")

--- The runs of `text`, as `{ words, group }` with the refs and styles
--- left out -- what most of these ask about.
local function runs_of(text, opts)
  local drawn, runs = markdown.inline(text, opts)
  local out = {}
  for _, run in ipairs(runs or { { drawn } }) do
    table.insert(out, { run[1], run[2] })
  end
  return drawn, out, runs
end

describe("markdown", function()
  describe("a line", function()
    it("a link is drawn as its words, and keeps where it goes", function()
      local drawn, _, runs = runs_of("see [the docs](https://x.test/d) first")
      assert.same("see the docs first", drawn)
      assert.same("RenderLink", runs[2][2])
      assert.same({ kind = "url", text = "the docs", href = "https://x.test/d" }, runs[2].ref)
      local _, _, rel = runs_of("[intro](docs/intro.md#setup)")
      assert.same("path", rel[1].ref.kind, "a relative link is a path")
      assert.same("image", (markdown.inline("![](pic.png)")), "a picture with no words")
      assert.same("a cat", (markdown.inline("![a cat](cat.png)")), "and with some")
    end)

    it("a URL on its own is a link, without what ends the sentence", function()
      local drawn, _, runs = runs_of("at https://x.test/a.")
      assert.same("at https://x.test/a.", drawn)
      assert.same("https://x.test/a", runs[2].ref.href)
      assert.same("https://x.test/b", (markdown.inline("<https://x.test/b>")))
    end)

    it("emphasis is a weight on the words, and the markers are gone", function()
      local drawn, _, runs = runs_of("a **bold** and *slanted* ~~gone~~ word")
      assert.same("a bold and slanted gone word", drawn)
      assert.same({ "RenderBold" }, runs[2].style)
      assert.same({ "RenderItalic" }, runs[4].style)
      assert.same({ "RenderStrike" }, runs[6].style)
      assert.same("snake_case_name", (markdown.inline("snake_case_name")), "inside a word, no")
      assert.same("2 * 3 * 4", (markdown.inline("2 * 3 * 4")), "arithmetic, no")
      assert.same("a *glob*", (markdown.inline([[a \*glob\*]])), "escaped, no")
    end)

    it("a code span is code, and nothing inside it is markup", function()
      local drawn, out = runs_of("run `a_b *c* [x](y)` now")
      assert.same("run a_b *c* [x](y) now", drawn)
      assert.same({ "a_b *c* [x](y)", "RenderCode" }, out[2])
      assert.same("a `b` c", (markdown.inline("a `` `b` `` c")), "a backtick, written down")
    end)

    it("a formula is the characters it would be printed with", function()
      assert.same("so α ≤ x²", (markdown.inline("so $\\alpha \\le x^2$")))
      assert.same("$5 or $10", (markdown.inline("$5 or $10")), "and money is money")
    end)

    it("a character reference is its character", function()
      assert.same([[it's "so" & —]], (markdown.inline("it&#39;s &quot;so&quot; &amp; &#x2014;")))
    end)

    it("every reading can be turned off", function()
      assert.same("[a](b)", (markdown.inline("[a](b)", { links = false })))
      assert.same("**a**", (markdown.inline("**a**", { styles = false })))
      assert.same("$x$", (markdown.inline("$x$", { math = false })))
    end)

    it("a caller draws in its own groups, and reads what it knows", function()
      local _, _, runs = runs_of("**a** [b](https://x.test/commit/1)", {
        groups = { bold = "MyBold" },
        link = function(url)
          if url:find("/commit/") then
            return { text = "commit 1", hl = "MyCommit", ref = { kind = "commit" } }
          end
        end,
      })
      assert.same({ "MyBold" }, runs[1].style)
      assert.same({ "commit 1", "MyCommit" }, { runs[3][1], runs[3][2] })
      local drawn, _, more = runs_of("ping @alice", {
        claims = {
          function(text, claim)
            local from, to = text:find("@%w+")
            if from then
              claim(from, to, text:sub(from, to), "MyMention", { kind = "mention" })
            end
          end,
        },
      })
      assert.same("ping @alice", drawn)
      assert.same("MyMention", more[2][2])
    end)
  end)

  describe("the blocks", function()
    local function kinds(blocks)
      return vim.tbl_map(function(b)
        return b.kind
      end, blocks)
    end

    it("each is what it was written as, and knows its line", function()
      local blocks = markdown.blocks({
        "# Title", --  1
        "", --         2
        "words", --    3
        "", --         4
        "- one", --    5
        "  1. two", -- 6
        "", --         7
        "| a | b |", -- 8
        "|---|--:|", -- 9
        "| 1 | 2 |", -- 10
        "", --         11
        "```lua", --   12
        "x = 1", --    13
        "```", --      14
        "> said", --   15
        "", --         16
        "---", --      17
      })
      assert.same({
        "heading",
        "prose",
        "prose",
        "prose",
        "item",
        "item",
        "prose",
        "table",
        "prose",
        "code",
        "citation",
        "prose",
        "rule",
      }, kinds(blocks))
      assert.same(
        { 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 15, 16, 17 },
        vim.tbl_map(function(b)
          return b.row
        end, blocks)
      )
      assert.same("lua", blocks[10].lang)
      assert.same({ "left", "right" }, blocks[8].align)
      assert.same("1.", blocks[6].marker, "numbered")
      assert.same(1, blocks[6].depth, "and nested")
    end)

    it("a line underlined is a heading", function()
      local blocks = markdown.blocks({ "Title", "=====", "", "Part", "----" })
      assert.same({ "heading", "prose", "heading" }, kinds(blocks))
      assert.same({ 1, 2 }, { blocks[1].level, blocks[3].level })
    end)

    it("a citation is blocks again, and its lines are the file's", function()
      local blocks = markdown.blocks({ "x", "> # quoted", "> words" })
      local inner = blocks[2].blocks
      assert.same({ "heading", "prose" }, kinds(inner))
      assert.same({ 2, 3 }, { inner[1].row, inner[2].row })
    end)

    it("joined, a paragraph is one block and a break is still a break", function()
      local blocks = markdown.blocks({
        "one",
        "two\\",
        "three",
        "",
        "- item",
        "  goes on",
        "four",
      }, { join = true })
      assert.same({ "prose", "prose", "prose", "item", "prose" }, kinds(blocks))
      assert.same("one two", blocks[1].text)
      assert.same("three", blocks[2].text, "after a hard break")
      assert.same("item goes on", blocks[4].text, "an item and what carries it on")
      assert.same(3, #markdown.blocks({ "one", "two", "three" }), "unjoined, a line each")
    end)

    it("a link by reference goes where its definition says", function()
      local lines =
        { "see [the cli][cli] or [`cli`][cli] or [cli]", "", "[CLI]: https://x.test/cli" }
      local defs = markdown.definitions(lines)
      assert.same({ cli = "https://x.test/cli" }, defs)
      local drawn, runs = markdown.inline(lines[1], { definitions = defs })
      assert.same("see the cli or cli or cli", drawn)
      assert.same("https://x.test/cli", runs[2].ref.href)
      assert.same("https://x.test/cli", runs[4].ref.href, "a code span in the words")
      assert.same(
        "[nope]",
        (markdown.inline("[nope]", { definitions = defs })),
        "no definition, no link"
      )
      assert.same("definition", markdown.blocks(lines)[3].kind, "and the definition is not drawn")
    end)

    it("a fence a caller knows better is what it says it is", function()
      local blocks = markdown.blocks({ "```suggestion:-1+0", "x", "```" }, {
        fence = function(block)
          if block.info:match("^suggestion") then
            return { kind = "suggestion", lines = block.lines }
          end
        end,
      })
      assert.same("suggestion", blocks[1].kind)
      assert.same(1, blocks[1].row)
    end)
  end)
end)
