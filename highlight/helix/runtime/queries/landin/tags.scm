(function_declaration name: (identifier) @name) @definition.function
(extern_declaration name: (identifier) @name) @definition.function
(type_declaration name: (identifier) @name) @definition.type
(concept_declaration name: (identifier) @name) @definition.interface
(call_expression function: (indexed_expression (identifier) @name)) @reference.call
(labeled_application function: (indexed_expression (identifier) @name)) @reference.call
