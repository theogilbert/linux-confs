; outer function textobject
(function_declaration) @function.outer

; outer function literals
(func_literal
  (_)?) @function.outer

; method as outer function textobject
(method_declaration
  body: (block)?) @function.outer

; struct and interface declaration as class textobject?
(type_declaration
  (type_spec
    (type_identifier)
    (struct_type))) @class.outer

(type_declaration
  (type_spec
    (type_identifier)
    (interface_type))) @class.outer

; struct literals as class textobject
(composite_literal
  (literal_value)) @class.outer

; conditionals
(if_statement
  alternative: (_
    (_) @conditional.inner)?) @conditional.outer

(if_statement
  condition: (_) @conditional.inner)

; loops
(for_statement) @loop.outer

; blocks
(_
  (block) @block.inner) @block.outer

; statements
(block
  (_) @statement.outer)

; comments
(comment) @comment.outer

; calls
(call_expression) @call.outer

(parameter_declaration
  name: (identifier)
  type: (_)) @parameter.inner

(parameter_declaration
  name: (identifier)
  type: (_)) @parameter.inner

; assignments
(short_var_declaration
  left: (_) @assignment.lhs
  right: (_) @assignment.rhs @assignment.inner) @assignment.outer

(assignment_statement
  left: (_) @assignment.lhs
  right: (_) @assignment.rhs @assignment.inner) @assignment.outer

(var_declaration
  (var_spec
    name: (_) @assignment.lhs
    value: (_) @assignment.rhs @assignment.inner)) @assignment.outer

(var_declaration
  (var_spec
    name: (_) @assignment.inner
    type: (_))) @assignment.outer

(const_declaration
  (const_spec
    name: (_) @assignment.lhs
    value: (_) @assignment.rhs @assignment.inner)) @assignment.outer

(const_declaration
  (const_spec
    name: (_) @assignment.inner
    type: (_))) @assignment.outer
