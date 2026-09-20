(source_file) @local.scope
(function_declaration) @local.scope
(extern_declaration body: (block)) @local.scope
(anonymous_function) @local.scope
(bare_block) @local.scope
(labeled_block) @local.scope

(binding name: (identifier_list (identifier) @local.definition))
(parameter name: (identifier_list (identifier) @local.definition))
(parameter name: (identifier) @local.definition)
(named_return name: (identifier_list (identifier) @local.definition))
(type_formal name: (identifier) @local.definition)
(identifier) @local.reference
