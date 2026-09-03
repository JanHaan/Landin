; Comments
(comment) @comment

; Literals
(integer_literal) @number
(boolean_literal) @boolean
(zeroed_literal) @constant.builtin

; Declarations and names
(function_declaration name: (identifier) @function)
(extern_declaration name: (identifier) @function)
(type_declaration name: (identifier) @type.definition)
(concept_declaration name: (identifier) @type.definition)
(atom_declaration name: (identifier_list (identifier) @constant))
(binding name: (identifier) @variable)
(parameter name: (identifier) @variable.parameter)
(named_return name: (identifier) @variable.parameter)
(type_formal name: (identifier) @type.parameter)
(field name: (identifier) @property)
(field_value name: (identifier) @property)
(variant_part name: (identifier) @property)
(variant_case name: (identifier) @constant)
(concept_entry name: (identifier) @function.method)
(labeled_argument name: (identifier) @variable.parameter)
(conformance_argument name: (identifier) @variable.parameter)
(member_selection member: (identifier) @property)

(call_expression function: (indexed_expression (identifier) @function.call))
(labeled_application function: (indexed_expression (identifier) @function.call))

(scalar_type) @type.builtin
(declaration_reference (identifier) @type)

; Keywords
[
  "addr" "alignof" "any" "atom" "begin" "concept" "dec" "defer"
  "else" "elsif" "end" "escaping" "fail" "fixed" "from" "if"
  "import" "in" "inc" "inout" "is" "match" "mut" "none"
  "ptr" "public" "return" "sink" "sizeof" "struct" "then" "try"
  "type" "undo" "when"
] @keyword

(measurement_expression
  operator: (identifier) @keyword
  (#eq? @keyword "lenof"))

(of_keyword
  (identifier) @keyword
  (#eq? @keyword "of"))

["and" "not" "or"] @keyword.operator

; Operators and punctuation
[
  "=" ":=" "!" "|" "+" "*" "/" "%" "+%"
  "*%" "<<" ">>" "&" "^" "~" "==" "<>" "<" "<=" ">" ">="
  ".." "..<"
] @operator

[
  (minus)
  (arrow)
  (minus_percent)
] @operator

["(" ")" "[" "]"] @punctuation.bracket
[":" "," "." "/"] @punctuation.delimiter
