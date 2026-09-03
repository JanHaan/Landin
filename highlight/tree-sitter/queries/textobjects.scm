(function_declaration) @function.around
(function_declaration body: (block) @function.inside)
(anonymous_function) @function.around
(anonymous_function body: (block) @function.inside)

[
  (struct_body)
  (concept_body)
] @class.around

(comment) @comment.around
