(source_file) @local.scope
(function_declaration) @local.scope
(anonymous_function) @local.scope
(bare_block) @local.scope

(binding name: (identifier) @local.definition)
(parameter name: (identifier) @local.definition)
(named_return name: (identifier) @local.definition)
(type_formal name: (identifier) @local.definition)
(identifier) @local.reference
