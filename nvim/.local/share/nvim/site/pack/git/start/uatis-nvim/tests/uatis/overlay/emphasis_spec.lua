-- difftastic tints a changed atom, and where the atom is prose its own
-- display picks out the words that are actually new. Its JSON reports
-- the tint alone, so the words are worked out here and drawn by
-- stepping back everything that is NOT them. Three things to get right:
-- the words, on a hunk whose sides do not pair up; the reach -- a row of
-- the node whose two sides are the same text is left alone; and the
-- restraint -- nothing of the sort on a line of code.
--
-- Drawn with `before = false`: these are statements about the new side.
local h = require("helpers")

local function drawn(old, new, expected)
  h.drawn({ lang = "python", old = old, new = new, opts = { before = false } }, expected)
end

describe("emphasis inside prose", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- Row 5 changed: an old half to skim, a new half to read. Row 6 is
  -- the line it gained, all edit, so there is nothing to step back FROM.
  -- The other rows of the docstring arrived tinted, being one atom, and
  -- are the same text they always were.
  it("lights the new words of a docstring that gained a line", function()
    drawn([[
      def f(path):
          """Draw it.

          Raises:
              DiagramError: If path does not resolve to a table.
          """
          return 1
    ]], [[
      def f(path):
          """Draw it.

          Raises:
              DiagramError: If path does not resolve to a table, or if no
                  spacing lets every relationship be drawn.
          """
          return 1
    ]], [[
      | def f(path):
      |     """Draw it.
      |
      |     Raises:
      ~         DiagramError: If path does not resolve to a table⟦, or if no⟧
      +             spacing lets every relationship be drawn.
      |     """
      |     return 1
    ]])
  end)

  -- The intra-line comparison used to refuse a block past
  -- `inline_token_limit` tokens outright, so a long query with one line
  -- appended was drawn at full tint end to end. The cap belongs on the
  -- pairing, which an appended line does not use.
  it("leaves a long string alone around the one line appended to it", function()
    local sql = { "import db", "", "", 'QUERY = """', "SELECT id, name, email", "FROM users" }
    for i = 1, 25 do
      table.insert(sql, ("JOIN accounts_%d ON accounts_%d.user_id = users.id AND accounts_%d.active = true")
        :format(i, i, i))
    end
    table.insert(sql, "ORDER BY users.created_at DESC")
    local closing = { '"""', "", "", "def run(conn):", "    return conn.execute(QUERY)" }
    local old = vim.list_extend(vim.deepcopy(sql), closing)
    table.insert(sql, "LIMIT 100")
    local new = vim.list_extend(sql, closing)
    assert.is_true(#table.concat(old, "\n") > 400, "bigger than one run may be paired over")
    drawn(old, new, [[
      | import db
      |
      |
      | QUERY = """
      | SELECT id, name, email
      | FROM users
      | JOIN accounts_1 ON accounts_1.user_id = users.id AND accounts_1.active = true
      | JOIN accounts_2 ON accounts_2.user_id = users.id AND accounts_2.active = true
      | JOIN accounts_3 ON accounts_3.user_id = users.id AND accounts_3.active = true
      | JOIN accounts_4 ON accounts_4.user_id = users.id AND accounts_4.active = true
      | JOIN accounts_5 ON accounts_5.user_id = users.id AND accounts_5.active = true
      | JOIN accounts_6 ON accounts_6.user_id = users.id AND accounts_6.active = true
      | JOIN accounts_7 ON accounts_7.user_id = users.id AND accounts_7.active = true
      | JOIN accounts_8 ON accounts_8.user_id = users.id AND accounts_8.active = true
      | JOIN accounts_9 ON accounts_9.user_id = users.id AND accounts_9.active = true
      | JOIN accounts_10 ON accounts_10.user_id = users.id AND accounts_10.active = true
      | JOIN accounts_11 ON accounts_11.user_id = users.id AND accounts_11.active = true
      | JOIN accounts_12 ON accounts_12.user_id = users.id AND accounts_12.active = true
      | JOIN accounts_13 ON accounts_13.user_id = users.id AND accounts_13.active = true
      | JOIN accounts_14 ON accounts_14.user_id = users.id AND accounts_14.active = true
      | JOIN accounts_15 ON accounts_15.user_id = users.id AND accounts_15.active = true
      | JOIN accounts_16 ON accounts_16.user_id = users.id AND accounts_16.active = true
      | JOIN accounts_17 ON accounts_17.user_id = users.id AND accounts_17.active = true
      | JOIN accounts_18 ON accounts_18.user_id = users.id AND accounts_18.active = true
      | JOIN accounts_19 ON accounts_19.user_id = users.id AND accounts_19.active = true
      | JOIN accounts_20 ON accounts_20.user_id = users.id AND accounts_20.active = true
      | JOIN accounts_21 ON accounts_21.user_id = users.id AND accounts_21.active = true
      | JOIN accounts_22 ON accounts_22.user_id = users.id AND accounts_22.active = true
      | JOIN accounts_23 ON accounts_23.user_id = users.id AND accounts_23.active = true
      | JOIN accounts_24 ON accounts_24.user_id = users.id AND accounts_24.active = true
      | JOIN accounts_25 ON accounts_25.user_id = users.id AND accounts_25.active = true
      | ORDER BY users.created_at DESC
      + LIMIT 100
      | """
      |
      |
      | def run(conn):
      |     return conn.execute(QUERY)
    ]])
  end)

  it("never steps back a line of code, whose atoms are tokens", function()
    drawn("def f(nodes, edges):\n    result = place(nodes, edges)\n    return result",
      "def f(nodes, edges):\n    undrawn = len(edges) - len(routed)\n    return undrawn", [[
        | def f(nodes, edges):
        |     ⟦undrawn = len⟧(edges) ⟦- len(routed)⟧
        |     return ⟦undrawn⟧
      ]])
  end)

  -- Stepping back needs two halves: other words for the new ones to
  -- stand out from, or something new inside. A `"|"` hoisted onto a line
  -- of its own has neither, and came out grey in a green row.
  it("does not step back a short literal with nothing new in it", function()
    drawn('def f(col, rows):\n    rows.append((col.name, "|".join(col.types)))\n    return rows',
      'def f(col, rows):\n    types = "|".join(_base_type(t) for t in col.types)\n'
        .. "    rows.append((col.name, types))\n    return rows", [[
          | def f(col, rows):
          +     types = "|".join(_base_type(t) for t in col.types)
          |     rows.append((col.name, types))
          |     return rows
        ]])
  end)

  -- The half that does hold: the `2` is there to point at. The quotes
  -- step back too -- the literal is almost all old and its closing quote
  -- sits where it always did (`diff.line.major_ratio` draws that line).
  it("steps back a literal around the character it gained", function()
    drawn("def f():\n    name = 'alpha'\n    return name",
      "def f():\n    name = 'alpha2'\n    return name", [[
        | def f():
        |     name = ⟨'alpha⟩⟦2⟧⟨'⟩
        |     return name
      ]])
  end)
end)

-- `emphasis_ratio` measures how much of the NEW atom is new, the wrong
-- side: `"diagram"` -> `"structural diagram"` is eleven of twenty new,
-- so it read as a rewrite and lit a word that did not change. Where
-- NOTHING was removed from a row that HAS an old half, every character
-- dimmed is genuinely the old atom (`lost`).
describe("nothing removed", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local function one(old, new, expected)
    h.drawn({ lang = "python", old = "X = 1\n" .. old .. "\nY = 2\n",
      new = "X = 1\n" .. new .. "\nY = 2\n" }, expected)
  end

  it("steps back the word a short string kept", function()
    one('HEADER = "diagram"', 'HEADER = "structural diagram"', [[
      | X = 1
      | HEADER = ⟨"⟩⟦structural ⟧⟨diagram"⟩
      | Y = 2
    ]])
  end)

  -- ...and the ratio still governs where something DID go: a rewrite
  -- leaves fragments matched by coincidence.
  it("leaves a string mostly rewritten tinted whole", function()
    one('H = "pip install grannos-py"', 'H = "grannos is a server, so install it as a tool"', [[
      | X = 1
      - H = "pip install grannos-py"
      | H = ⟦"grannos is a server, so install it as a tool"⟧
      | Y = 2
    ]])
  end)

  -- A hunk folding several rows into fewer has no pairing to offer: the
  -- new row replaced all of them, and the emphasis over the whole block
  -- lifted `plan.title` and `plan.author` out of two different old rows.
  it("but several lines becoming one is a replacement, drawn under the block", function()
    h.drawn({ lang = "python", old = {
      "def describe(plan):",
      "    parts = []",
      '    parts.append("title: " + plan.title)',
      '    parts.append("author: " + plan.author)',
      '    parts.append("scale: " + str(plan.scale))',
      '    return "\\n".join(parts)',
      "",
    }, new = {
      "def describe(plan):",
      '    return f"{plan.title} by {plan.author}"',
      "",
    } }, [[
      | def describe(plan):
      -     parts = []
      -     parts.append("title: " + plan.title)
      -     parts.append("author: " + plan.author)
      -     parts.append("scale: " + str(plan.scale))
      - ⟨    return ⟩"\n".join(parts)
      |     return ⟦f"{plan.title} by {plan.author}"⟧
      |
    ]])
  end)
end)

-- A file difftastic has no parser for is words to it, and a reworded
-- line of prose there reads as it does inside a parsed docstring.
describe("a reworded sentence", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local sentence = "A diagram is a structural overview. It says what talks to "

  it("steps back with the new word lit in an unparsed file", function()
    local old = "# Guide\n\n" .. sentence .. "what, and a\nlength says nothing at all about how long anything takes.\n"
    h.drawn({ lang = "markdown", path = "guide.md", old = old,
      new = (old:gsub("nothing at all about", "nothing whatsoever about")) }, [[
        | # Guide
        |
        | A diagram is a structural overview. It says what talks to what, and a
        - ⟨length says nothing ⟩at all⟨ about how long anything takes.⟩
        ~ length says nothing ⟦whatsoever⟧ about how long anything takes.
      ]])
  end)

  it("which is what a parsed docstring does", function()
    local old = 'def f():\n    """A diagram says nothing at all about how long."""\n    return 1\n'
    h.drawn({ lang = "python", old = old,
      new = (old:gsub("nothing at all about", "nothing whatsoever about")) }, [[
        | def f():
        - ⟨    """A diagram says nothing ⟩at all⟨ about how long."""⟩
        ~     """A diagram says nothing ⟦whatsoever⟧ about how long."""
        |     return 1
      ]])
  end)
end)
