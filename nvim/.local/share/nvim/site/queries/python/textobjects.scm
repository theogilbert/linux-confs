((decorated_definition)?
  (function_definition
    body: (block)? @function.inner)) @function.outer

((decorated_definition)?
  (class_definition
    body: (block)? @class.inner)) @class.outer

(while_statement
  body: (block)? @loop.inner) @loop.outer

(for_statement
  body: (block)? @loop.inner) @loop.outer

(if_statement
  alternative: (_
    (_) @conditional.inner)?) @conditional.outer

(if_statement
  consequence: (block)? @conditional.inner)

(if_statement
  condition: (_) @conditional.inner)

(_
  (block) @block.inner) @block.outer

; leave space after comment marker if there is one
((comment) @comment.inner @comment.outer
  (#offset! @comment.inner 0 2 0)
  (#lua-match? @comment.outer "# .*"))

; else remove everything accept comment marker
((comment) @comment.inner @comment.outer
  (#offset! @comment.inner 0 1 0))

(block
  (_) @statement.outer)

(module
  (_) @statement.outer)

(call) @call.outer


(return_statement
  (_)? @return.inner) @return.outer

[
  (integer)
  (float)
] @number.inner

(assignment
  left: (_) @assignment.lhs
  right: (_) @assignment.inner @assignment.rhs) @assignment.outer

(assignment
  left: (_) @assignment.inner)

(augmented_assignment
  left: (_) @assignment.lhs
  right: (_) @assignment.inner @assignment.rhs) @assignment.outer

(augmented_assignment
  left: (_) @assignment.inner)

; TODO: exclude comments using the future negate syntax from tree-sitter
