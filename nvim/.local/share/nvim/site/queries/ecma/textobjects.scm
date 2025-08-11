(function_declaration
  body: (statement_block)) @function.outer

(generator_function_declaration
  body: (statement_block)) @function.outer

(function_expression
  body: (statement_block)) @function.outer

(export_statement
  (function_declaration)) @function.outer

(arrow_function
  body: (_) @function.inner) @function.outer

(method_definition
  body: (statement_block)) @function.outer

(class_declaration
  body: (class_body)) @class.outer


(export_statement
  (class_declaration)) @class.outer

(if_statement) @conditional.outer

(switch_statement
  body: (_)? @conditional.inner) @conditional.outer

(call_expression) @call.outer


; blocks
(_
  (statement_block) @block.inner) @block.outer

; parameters
; function ({ x }) ...
; function ([ x ]) ...
; function (v = default_value)

; comment
(comment) @comment.outer

; regex
(regex
  (regex_pattern) @regex.inner) @regex.outer

; number
(number) @number.inner

(lexical_declaration
  (variable_declarator
    name: (_) @assignment.lhs
    value: (_) @assignment.inner @assignment.rhs)) @assignment.outer

(variable_declarator
  name: (_) @assignment.inner)

(object
  (pair
    key: (_) @assignment.lhs
    value: (_) @assignment.inner @assignment.rhs) @assignment.outer)

(return_statement
  (_) @return.inner) @return.outer

(return_statement) @statement.outer

[
  (if_statement)
  (expression_statement)
  (for_statement)
  (while_statement)
  (do_statement)
  (for_in_statement)
  (export_statement)
  (lexical_declaration)
] @statement.outer

; 1.  default import
(import_statement
  (import_clause
    (identifier) @parameter.inner @parameter.outer))

; 2.  namespace import  e.g. `* as React`
(import_statement
  (import_clause
    (namespace_import
      (identifier) @parameter.inner) @parameter.outer))

; 3.  named import  e.g. `import { Bar, Baz } from ...`
(import_statement
  (import_clause
    (named_imports
      (import_specifier) @parameter.inner)))


; 3-C.  only one named import without a comma
(import_statement
  (import_clause
    (named_imports
      .
      (import_specifier) @parameter.outer .)))

; Treat list or object elements as @parameter
; 1. parameter.inner
(object
  (_) @parameter.inner)

(array
  (_) @parameter.inner)

(object_pattern
  (_) @parameter.inner)

(array_pattern
  (_) @parameter.inner)

; 2. parameter.outer: Only one element, no comma
(object
  .
  (_) @parameter.outer .)

(array
  .
  (_) @parameter.outer .)

(object_pattern
  .
  (_) @parameter.outer .)

(array_pattern
  .
  (_) @parameter.outer .)
