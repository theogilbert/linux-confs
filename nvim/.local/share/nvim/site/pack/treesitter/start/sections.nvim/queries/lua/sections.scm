((function_declaration
   name: (identifier) @section.name
   parameters: (parameters (identifier) @section.param)?
   ) @section
 (#set! type "function")
 )

((assignment_statement
   ( variable_list
     name: (_) @section.name
     )
   (
    (expression_list
      value: (function_definition
               parameters: (parameters
                             (identifier)? @section.param)))
    )
   ) @section
 (#set! type "function")
 )

