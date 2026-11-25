local markdown = require("render.markdown")

describe("tex", function()
  -- A formula as the characters it would be printed with: a
  -- substitution, not a typesetter, and what it does not know left as
  -- it was written.
  it("the Greek, a relation and the scripts", function()
    local tex = require("render.tex")
    assert.same(
      "α ≤ x² + yᵢ",
      tex.render([[\alpha \le x^2 + y_i]]),
      "the Greek, a relation and the scripts"
    )
    assert.same("xⁿ⁺¹", tex.render([[x^{n+1}]]), "a script Unicode has whole")
    assert.same("e^(iπ)", tex.render([[e^{i\pi}]]), "and one it has not, bracketed")
    assert.same("(a+b)/2", tex.render([[\frac{a+b}{2}]]), "a fraction on one line, held together")
    assert.same("n(n+1)/2", tex.render([[\frac{n(n+1)}{2}]]), "and not bracketed twice")
    assert.same(
      "³√8 + √(x+1)",
      tex.render([[\sqrt[3]{8} + \sqrt{x+1}]]),
      "a root, and its index"
    )
    assert.same(
      "ℝ if ( x )",
      tex.render([[\mathbb{R} \text{ if } \left( x \right)]]),
      "the faces and sizes go"
    )
    assert.same("\\unknownx", tex.render([[\unknown{x}]]), "a command it does not know stays")
    assert.same(
      { "1  x > 0", "0  else" },
      tex.lines([[\begin{cases} 1 & x > 0 \\ 0 & \text{else} \end{cases}]]),
      "a row of an environment on a line of its own"
    )
    assert.same(
      "costs O(n) and x², or $5 or $10",
      (markdown.inline("costs $O(n)$ and $`x^2`$, or $5 or $10")),
      "in a sentence, and money is not a formula"
    )
    assert.same("$a$", (markdown.inline("`$a$`")), "nor is a dollar in a code span")
    assert.same("RenderMath", select(2, markdown.inline("$x$"))[1][2], "in a colour of its own")
    local blocks = markdown.blocks({ "$$", "a^2", "$$", "$$ b $$", "```math", "c", "```" })
    assert.same(3, #blocks, "a displayed one is a block, however it is spelled")
    assert.same({ "", "a^2", "" }, blocks[1].lines, "with the lines between the $$s")
    assert.same("math", blocks[3].kind, "and a math fence is one too")
  end)
end)
