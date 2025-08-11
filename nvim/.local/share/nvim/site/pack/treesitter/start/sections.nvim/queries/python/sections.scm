(
  (function_definition
    name: (identifier) @section.name
    parameters: (parameters
      [
        (identifier) @section.param
        (typed_parameter (identifier) @section.param)
        (default_parameter name: (identifier) @section.param)
        (typed_default_parameter name: (identifier) @section.param)
      ]
    )?
  ) @section
  (#not-match? @section.name "^_")
  (#set! type "function")
)

(
  (function_definition
    name: (identifier) @section.name
    parameters: (parameters
      [
        (identifier) @section.param
        (typed_parameter (identifier) @section.param)
        (default_parameter name: (identifier) @section.param)
        (typed_default_parameter name: (identifier) @section.param)
      ]
    )?
  ) @section
  (#match? @section.name "^_")
  (#set! private "true")
  (#set! type "function")
)


(
  (class_definition
    name: (identifier) @section.name
    superclasses: (argument_list (identifier) @section.param)*
  ) @section
  (#not-match? @section.name "^_")
  (#set! type "class")
)

(
  (class_definition
    name: (identifier) @section.name
    superclasses: (argument_list (identifier) @section.param)*
  ) @section
  (#match? @section.name "^_")
  (#set! private "true")
  (#set! type "class")
)

(
  (class_definition
    body: (block
            (expression_statement
              (assignment
                left: (identifier) @section.name
                type: (type (identifier) @section.type_annotation)?
                )
              ) @section
            )
  )
  (#not-match? @section.name "^_")
  (#set! type "attribute")
)

(
  (class_definition
    body: (block
            (expression_statement
              (assignment
                left: (identifier) @section.name
                type: (type (identifier) @section.type_annotation)?
                )
              ) @section
            )
  )
  (#match? @section.name "^_")
  (#set! private "true")
  (#set! type "attribute")
)

(
  (module
    (expression_statement
      (assignment
        left: (identifier) @section.name
        type: (type (identifier) @section.type_annotation)?
        )
      ) @section
  )
  (#not-match? @section.name "^_")
  (#set! type "attribute")
)

(
  (module
    (expression_statement
      (assignment
        left: (identifier) @section.name
        type: (type (identifier) @section.type_annotation)?
        )
      ) @section
  )
  (#match? @section.name "^_")
  (#set! private "true")
  (#set! type "attribute")
)
