/**
 * @file Incremental concrete-syntax grammar for Landin editor tooling.
 * @license MIT OR Apache-2.0
 *
 * This is a checked rendering of spec.md [1740]-[1820], not a normative
 * language definition.  check.py holds its vocabulary and precedence to the
 * specification and the fixture corpus holds its accepted surface to refine.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  logical_or: 1,
  logical_and: 2,
  comparison: 3,
  alternation: 4,
  exclusion: 5,
  conjunction: 6,
  shift: 7,
  sum: 8,
  product: 9,
  unary: 10,
  // Above the assignment statement's 100: a selector or call that follows
  // an expression extends it, and must win the static shift/reduce
  // decision against closing the statement and reading `[` as a literal.
  selection: 110,
  call: 120,
};

module.exports = grammar({
  name: 'landin',

  word: $ => $.identifier,
  inline: $ => [$._declaration_name],

  reserved: {
    global: $ => [
      'addr', 'alignof', 'and', 'any', 'atom', 'dec', 'else', 'elsif', 'end',
      'escaping', 'extern', 'fail', 'false', 'fixed', 'from', 'if', 'import',
      'in', 'inc', 'inout', 'mut', 'none', 'not', 'or', 'ptr', 'public',
      'return', 'sink', 'sizeof', 'struct', 'then', 'true', 'try', 'type',
      'when', 'zeroed',
    ],
  },

  externals: $ => [
    $.comment,
    $.minus,
    $.arrow,
    $.minus_percent,
    $.minus_equals,
    $.minus_percent_equals,
  ],

  extras: $ => [
    /[ \t\r\n]/,
    $.comment,
  ],

  supertypes: $ => [
    $._declaration,
    $._type,
    $._expression,
    $._statement,
  ],

  conflicts: $ => [
    [$.import_declaration],
    [$.declaration_reference, $.indexed_expression],
    [$._type, $.type_application],
    [$.routine_formals, $.parameters],
    [$.routine_formals],
    [$.parameters],
    [$.labeled_arguments, $.arguments],
    [$.function_declaration],
    [$.extern_declaration],
    [$.struct_body],
    [$.concept_body],
    [$.destructured_field, $.indexed_expression],
    [$.destructured_field, $.indexed_expression, $.declaration_reference],
    [$.indexed_expression, $.declaration_reference, $.measurement_expression],
    [$.indexed_expression, $.measurement_expression, $.of_keyword],
    [$.measurement_expression, $.of_keyword],
    [$.indexed_expression, $.of_keyword],
    [$.indexed_expression, $.recovery_clause],
    [$.indexed_expression, $.measurement_expression],
    [$.call_expression],
    [$.labeled_application],
    [$.signature, $.declared_signature],
    [$.named_return],
    [$.variant_part],
    [$.block, $._statement],
    [$._statement, $._primary_expression],
    [$._value_statement, $._primary_expression],
    [$._type, $.indexed_expression],
    [$.binding, $.condition_declaration],
    [$.condition_declaration, $.indexed_expression],
    [$.condition_declaration, $.indexed_expression, $.declaration_reference],
    [$.condition_declaration, $.indexed_expression, $.declaration_reference, $.measurement_expression],
    [$.condition_declaration, $.indexed_expression, $.measurement_expression, $.of_keyword],
    [$.binding, $.loop_statement, $.while_statement, $.for_statement],
    [$.identifier_list, $.binding, $.type_declaration, $.concept_declaration, $.function_declaration, $.loop_statement, $.while_statement, $.for_statement],
    [$.identifier_list, $.binding, $.type_declaration, $.concept_declaration, $.function_declaration],
  ],

  rules: {
    source_file: $ => seq(
      repeat($.import_declaration),
      repeat($._declaration),
    ),


    import_declaration: $ => seq(
      'import', $.import_path,
      optional(choice(
        seq('as', field('alias', $.identifier)),
        seq('(', $.identifier_list, ')'),
      )),
    ),
    import_path: $ => seq($.identifier, repeat(seq('/', $.identifier))),

    _declaration: $ => choice(
      $.public_declaration,
      $.conformance_declaration,
      $.fixed_conditional,
      $.option_declaration,
      $.tool_directive,
    ),

    option_declaration: $ => seq(
      'option', field('name', $._declaration_name), ':', field('type', $._type),
      '=', field('value', $._expression),
    ),

    tool_directive: $ => seq(
      field('module', choice('compiler', 'assembler', 'linker')),
      '.', field('member', $.identifier), '(', optional($.arguments), ')',
    ),

    public_declaration: $ => seq(
      optional('public'),
      choice(
        $.atom_declaration,
        $.binding,
        $.function_declaration,
        $.extern_declaration,
        $.type_declaration,
        $.concept_declaration,
      ),
    ),

    extern_declaration: $ => seq(
      $.c_convention,
      optional($.link_symbol),
      field('name', $._declaration_name), ':', $.c_declared_signature,
      optional(seq(
        '=', optional(field('body', $.block)),
        'end', optional(field('end_name', $.identifier)),
      )),
    ),
    c_convention: $ => seq(
      'extern', '(', field('convention', alias('c', $.identifier)), ')',
    ),
    link_symbol: $ => seq(
      field('attribute', alias('link', $.identifier)), '(',
      field('label', alias('symbol', $.identifier)), ':',
      field('value', $.text_literal),
      ')',
    ),

    fixed_conditional: $ => seq(
      'fixed', 'if', field('condition', $._expression), 'then',
      repeat($._declaration),
      repeat(seq('elsif', field('condition', $._expression), 'then', repeat($._declaration))),
      optional(seq('else', repeat($._declaration))),
      'end', 'if',
    ),

    atom_declaration: $ => seq(field('name', $.identifier_list), ':', 'atom'),
    identifier_list: $ => seq($._declaration_name, repeat(seq(',', $.identifier))),
    // At a declaration start the lexer may also admit contextual import or
    // option syntax. Keep the ordinary name until the next token decides.
    _declaration_name: $ => choice(
      $.identifier,
      alias('option', $.identifier),
      alias('as', $.identifier),
      alias('link', $.identifier),
    ),

    binding: $ => choice(
      seq(
        optional('mut'),
        field('name', $._declaration_name),
        ':',
        field('type', $._type),
        optional(seq('=', field('value', $._expression))),
      ),
      seq(
        optional('mut'),
        field('name', $._declaration_name),
        ':=',
        field('value', $._expression),
      ),
    ),

    _type: $ => choice(
      $.function_type,
      $.array_type,
      $.pointer_type,
      $.slice_type,
      $.any_type,
      $.type_application,
      $.scalar_type,
      $.declaration_reference,
    ),

    function_type: $ => choice(
      $.signature,
      seq($.c_convention, $.c_signature),
    ),
    array_type: $ => seq('[', field('length', $._expression), ']', field('element', $._type)),
    pointer_type: $ => seq('ptr', optional('mut'), field('target', $._type)),
    slice_type: $ => seq('[', ']', optional('mut'), field('element', $._type)),
    any_type: $ => seq('any', field('concept', $.declaration_reference)),
    type_application: $ => seq(
      field('function', $.declaration_reference),
      '(',
      commaSep1(field('argument', $.type_argument)),
      ')',
    ),
    type_argument: $ => choice($._type, $.integer_literal),
    scalar_type: _ => choice(
      'u8', 'u16', 'u32', 'u64',
      'i8', 'i16', 'i32', 'i64',
      'usize', 'isize', 'bool', 'f32', 'f64',
    ),

    type_declaration: $ => seq(
      field('name', $._declaration_name), ':', 'type',
      choice(
        seq('=', choice($.atom_union, $.range_subtype, $._type, $.struct_body)),
        seq($.type_formals, '=', choice($._type, $.struct_body)),
      ),
    ),
    // [0660]: a scalar with a range it must stay in.
    range_subtype: $ => seq(
      field('base', $._type), 'range',
      field('lower', $._expression), field('operator', choice('..', '..<')),
      field('upper', $._expression),
    ),

    concept_declaration: $ => seq(
      field('name', $._declaration_name), ':', 'type', '=', $.concept_body,
    ),
    concept_body: $ => seq(
      'concept', $.type_formals,
      optional(seq('is', commaSep1($.declaration_reference))),
      repeat($.concept_entry),
      'end', optional($.identifier),
    ),
    concept_entry: $ => seq(field('name', $._declaration_name), ':', $.signature),

    conformance_declaration: $ => seq(
      optional($.type_formals),
      field('target', $.conformance_target),
      'is',
      field('concept', $.declaration_reference),
      '(', optional(commaSep1($.conformance_argument)), ')',
    ),
    conformance_target: $ => choice(
      $.array_type,
      $.pointer_type,
      $.slice_type,
      $.any_type,
      $.type_application,
      $.declaration_reference,
    ),
    conformance_argument: $ => seq(
      field('name', $._declaration_name), ':', field('value', $.argument_rhs),
    ),

    type_formals: $ => seq('(', commaSep1($.type_formal), ')'),
    type_formal: $ => choice(
      seq(
        field('name', $._declaration_name), ':', 'type',
        optional(seq('is', field('constraint', $.declaration_reference))),
      ),
      seq('fixed', field('name', $._declaration_name), ':', field('type', $._type)),
    ),

    // An atom set, or [0480]'s pointer union of atoms and one pointer.
    atom_union: $ => seq(
      $._union_member,
      '|',
      $._union_member,
      repeat(seq('|', $._union_member)),
    ),
    _union_member: $ => choice($.declaration_reference, $.pointer_type),

    struct_body: $ => seq(
      optional($.c_layout),
      'struct', repeat1(choice($.field, $.variant_part)), 'end', optional($.identifier),
    ),
    c_layout: $ => seq(
      field('attribute', alias('layout', $.identifier)), '(',
      field('convention', alias('c', $.identifier)),
      ')',
    ),
    field: $ => seq(field('name', $._declaration_name), ':', field('type', $._type)),
    variant_part: $ => seq(
      field('name', $._declaration_name), ':', 'variant',
      $.variant_case, repeat(seq('|', $.variant_case)),
      'end', optional($.identifier),
    ),
    variant_case: $ => seq(
      field('name', $._declaration_name),
      optional(seq(':', '(', commaSep1($.field), ')')),
    ),

    function_declaration: $ => seq(
      optional($.link_symbol),
      field('name', $._declaration_name), ':',
      $.declared_signature, '=',
      optional(field('body', $.block)),
      'end', optional(field('end_name', $.identifier)),
    ),
    anonymous_function: $ => prec.dynamic(1, seq(
      $.signature, '=', optional(field('body', $.block)), 'end',
    )),
    signature: $ => seq(
      '(', optional($.parameters), ')', $.arrow, $.returns, optional($.errors),
    ),
    c_signature: $ => seq(
      '(', optional(seq(
        $.parameters,
        optional(seq(',', $.variadic_marker)),
      )), ')', $.arrow, $.returns, optional($.errors),
    ),
    declared_signature: $ => seq(
      '(', optional($.routine_formals), ')', $.arrow, $.returns, optional($.errors),
    ),
    c_declared_signature: $ => seq(
      '(', optional(seq(
        $.routine_formals,
        optional(seq(',', $.variadic_marker)),
      )), ')', $.arrow, $.returns, optional($.errors),
    ),
    variadic_marker: _ => '...',
    routine_formals: $ => commaSep1(choice($.parameter, $.type_formal)),
    parameters: $ => commaSep1($.parameter),
    // `caller` marks D192's site parameter and is not reserved, so a
    // parameter may also be named caller.
    parameter: $ => choice(
      seq('caller', field('name', $._declaration_name), ':', field('type', $._type)),
      seq(field('name', alias('caller', $.identifier)), ':', field('type', $._type)),
      seq(
        optional('escaping'),
        optional($.parameter_convention),
        field('name', $._declaration_name), ':', field('type', $._type),
      ),
    ),
    parameter_convention: _ => choice('in', 'inout', 'sink'),
    returns: $ => choice(
      seq('(', optional(commaSep1($.named_return)), ')'),
      'none',
    ),
    named_return: $ => seq(
      field('name', $._declaration_name), ':', field('type', $._type),
      optional(seq('from', commaSep1($.identifier))),
    ),
    errors: $ => prec.right(seq(
      '!',
      choice('...', seq($.declaration_reference, repeat(seq('|', $.declaration_reference)))),
    )),

    block: $ => choice(
      repeat1($._statement),
      seq(repeat($._value_statement), field('value', $._expression)),
    ),
    // [1810]'s `value_statement`: everything that may precede a block's
    // value.  `unchecked` alone is a statement only.
    _statement: $ => prec.dynamic(3, choice(
      $._value_statement,
      $.unchecked_block,
    )),
    _value_statement: $ => prec.dynamic(5, choice(
      $.binding,
      $.destructuring_binding,
      $.assignment_statement,
      $.increment_statement,
      $.discard_statement,
      $.call_expression,
      $.labeled_application,
      $.try_expression,
      $.defer_statement,
      $.undo_statement,
      $.return_statement,
      $.fail_statement,
      $.break_statement,
      $.continue_statement,
      $.loop_statement,
      $.while_statement,
      $.for_statement,
      $.if_expression,
      $.match_expression,
      $.bare_block,
    )),

    // R4.10's loops, [1130]-[1190].  `loop`, `while`, `for`, `do`, `break`,
    // `continue`, `complete` and `with` are words [1760] does not reserve,
    // so they stay out of `reserved` and are keywords only where a rule
    // expects them, which is how the parser's refusal table treats them.
    loop_statement: $ => choice(
      seq('loop', 'do', optional($.block), 'end', 'loop'),
      seq(field('label', $.identifier), ':', 'loop', 'do', optional($.block),
          'end', field('end_label', $.identifier)),
    ),
    while_statement: $ => choice(
      seq('while', field('condition', $._condition), 'do', optional($.block),
          optional(seq('complete', optional(field('completion', $.block)))),
          'end', 'while'),
      seq(field('label', $.identifier), ':', 'while', field('condition', $._condition),
          'do', optional($.block),
          optional(seq('complete', optional(field('completion', $.block)))),
          'end', field('end_label', $.identifier)),
    ),
    for_statement: $ => choice(
      seq('for', $._traversal, 'do', optional($.block),
          optional(seq('complete', optional(field('completion', $.block)))),
          'end', 'for'),
      seq(field('label', $.identifier), ':', 'for', $._traversal, 'do', optional($.block),
          optional(seq('complete', optional(field('completion', $.block)))),
          'end', field('end_label', $.identifier)),
    ),
    _traversal: $ => seq(
      field('element', $.identifier), optional(seq(',', field('index', $.identifier))),
      'in', field('source', $._expression),
      optional(seq(field('operator', choice('..', '..<')), field('upper', $._expression))),
    ),
    break_statement: $ => prec.right(seq(
      'break',
      optional(field('label', $.identifier)),
      optional(seq('with', field('value', $._expression))),
      optional(seq('when', field('condition', $._expression))),
    )),
    continue_statement: $ => prec.right(seq(
      'continue',
      optional(field('label', $.identifier)),
      optional(seq('when', field('condition', $._expression))),
    )),
    unchecked_block: $ => seq('unchecked', 'begin', optional($.block), 'end', 'unchecked'),

    // [1140]'s condition may declare the value it tests.
    _condition: $ => choice($._expression, $.condition_declaration),
    condition_declaration: $ => choice(
      seq(optional('mut'), field('name', $._declaration_name), ':=', field('value', $._expression)),
      seq(optional('mut'), field('name', $._declaration_name), ':', field('type', $._type),
          '=', field('value', $._expression)),
    ),

    destructuring_binding: $ => seq(
      '(', commaSep1($.destructured_field), ')', ':=', $._expression,
    ),
    destructured_field: $ => choice(
      '_',
      seq(field('name', $._declaration_name), optional(seq(':', choice($.identifier, '_')))),
    ),
    assignment_statement: $ => prec.right(100, seq(
      field('left', $.place),
      field('operator', choice(
        '=', '+=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=',
        '+%=', '*%=', $.minus_equals, $.minus_percent_equals,
      )),
      field('right', $._expression),
    )),
    increment_statement: $ => seq(choice('inc', 'dec'), $.place),
    discard_statement: $ => seq('_', '=', $._expression),
    defer_statement: $ => seq('defer', $.call_expression),
    undo_statement: $ => seq('undo', $.call_expression),
    return_statement: $ => seq('return', optional(seq('when', $._expression))),
    fail_statement: $ => seq('fail', $._expression, optional(seq('when', $._expression))),

    if_expression: $ => prec.dynamic(4, prec.right(seq(
      'if', field('condition', $._condition), 'then', optional(field('consequence', $.block)),
      repeat(seq('elsif', field('condition', $._condition), 'then', optional(field('consequence', $.block)))),
      optional(seq('else', optional(field('alternative', $.block)))),
      'end', 'if',
    ))),
    match_expression: $ => prec.dynamic(4, seq(
      'match', field('value', $._expression), repeat1($.match_arm), 'end', 'match',
    )),
    match_arm: $ => seq(
      field('case', choice($.declaration_reference, 'ptr', '_')),
      optional(seq('(', commaSep1($.match_binding), ')')),
      ':', field('body', choice($._statement, $._expression)),
    ),
    match_binding: $ => seq(optional('inout'), field('name', $._declaration_name)),
    bare_block: $ => prec.dynamic(4, seq('begin', optional($.block), 'end')),

    place: $ => $.indexed_expression,

    _expression: $ => $.logical_or_expression,
    logical_or_expression: $ => binaryLevel($, PREC.logical_or, $.logical_and_expression, ['or']),
    logical_and_expression: $ => binaryLevel($, PREC.logical_and, $.comparison_expression, ['and']),
    comparison_expression: $ => choice(
      prec.dynamic(1, $.alternation_expression),
      prec.dynamic(2, prec.left(PREC.comparison, seq(
        $.alternation_expression,
        field('operator', choice('==', '<>', '<', '<=', '>', '>=')),
        $.alternation_expression,
      ))),
    ),
    alternation_expression: $ => binaryLevel($, PREC.alternation, $.exclusion_expression, ['|']),
    exclusion_expression: $ => binaryLevel($, PREC.exclusion, $.conjunction_expression, ['^']),
    conjunction_expression: $ => binaryLevel($, PREC.conjunction, $.shift_expression, ['&']),
    shift_expression: $ => binaryLevel($, PREC.shift, $.sum_expression, ['<<', '>>']),
    sum_expression: $ => binaryLevel($, PREC.sum, $.product_expression, ['+', $.minus, '+%', $.minus_percent]),
    product_expression: $ => binaryLevel($, PREC.product, $.unary_expression, ['*', '/', '%', '*%']),
    unary_expression: $ => prec.right(PREC.unary, seq(
      repeat(field('operator', choice($.minus, '~', 'not'))),
      $._primary_expression,
    )),

    _primary_expression: $ => choice(
      $.if_expression,
      $.match_expression,
      $.bare_block,
      $.loop_statement,
      $.while_statement,
      $.for_statement,
      $.literal,
      $.array_literal,
      $.array_repetition,
      $.struct_literal,
      $.empty_slice,
      $.labeled_application,
      $.anonymous_function,
      $.call_expression,
      $.indexed_expression,
      $.address_expression,
      $.pointer_conversion,
      $.any_construction,
      $.measurement_expression,
      $.try_expression,
      seq('(', $._expression, ')'),
    ),

    literal: $ => choice(
      $.float_literal, $.integer_literal, $.boolean_literal, $.zeroed_literal,
      $.character_literal, $.text_literal, $.raw_literal,
    ),
    boolean_literal: _ => choice('true', 'false'),
    zeroed_literal: _ => 'zeroed',
    // The float needs a fraction on both sides of its point, so `0..` in
    // a range never starts one; the hexadecimal form needs its exponent.
    float_literal: _ => token(prec(2, choice(
      /[0-9][0-9_]*\.[0-9][0-9_]*([eE][+-]?[0-9][0-9_]*)?/,
      /0[xX][0-9A-Fa-f][0-9A-Fa-f_]*\.[0-9A-Fa-f][0-9A-Fa-f_]*[pP][+-]?[0-9][0-9_]*/,
    ))),
    integer_literal: _ => token(choice(
      /0[xX][0-9A-Fa-f][0-9A-Fa-f_]*/,
      /0[oO][0-7][0-7_]*/,
      /0[bB][01][01_]*/,
      /[0-9][0-9_]*/,
    )),
    character_literal: _ => token(/'([^'\\\n]|\\[^\n])*'/),
    // A raw literal is a run of three quotes or more around any bytes.  A
    // token cannot count, so the three- and four-quote runs are spelled
    // out and a longer run is left to the compiler.
    raw_literal: _ => token(prec(3, choice(
      /""""([^"]|"[^"]|""[^"]|"""[^"])*""""/,
      /"""([^"]|"[^"]|""[^"])*"""/,
    ))),
    text_literal: _ => token(prec(1, /"([^"\\\n]|\\[^\n])*"/)),

    array_literal: $ => prec.dynamic(4, seq('[', commaSep1($._expression), ']')),
    array_repetition: $ => choice(
      seq('[', $.integer_literal, $.of_keyword, $._expression, ']'),
      seq('[', $.of_keyword, $._expression, ']'),
      seq('[', commaSep1($._expression), ',', $.of_keyword, $._expression, ']'),
    ),
    struct_literal: $ => prec(50, seq(
      '(', commaSep1($.field_value), optional(seq(',', $.of_keyword, $._expression)), ')',
    )),
    field_value: $ => seq(field('name', $._declaration_name), ':', field('value', $._expression)),

    labeled_application: $ => choice(
      prec(PREC.call, seq(
        field('function', $.indexed_expression), '(', $.labeled_arguments, ')',
      )),
      prec.dynamic(-2, prec.right(PREC.call, seq(
        field('function', $.indexed_expression), '(', $.labeled_arguments, ')',
        $.recovery_clause,
      ))),
    ),
    labeled_arguments: $ => seq(
      repeat(seq($._expression, ',')),
      commaSep1($.labeled_argument),
      optional(seq(',', $.of_keyword, $._expression)),
    ),
    labeled_argument: $ => seq(field('name', $._declaration_name), ':', field('value', $.argument_rhs)),
    argument_rhs: $ => choice($._expression, $._type),

    // A scalar type name heads an expression as a conversion (`u32(n)`)
    // or a named special (`f64.infinity`), so it stands where a name does.
    // Explicit left recursion rather than a repeat: the postfix production
    // itself carries the precedence, so a `[` or `.` after a selector
    // extends the chain instead of closing the statement around it.
    indexed_expression: $ => choice(
      prec.dynamic(1, choice($.identifier, $.scalar_type)),
      prec.dynamic(2, prec.left(PREC.selection, seq(
        $.indexed_expression,
        choice($.member_selection, $.index_selection),
      ))),
    ),
    member_selection: $ => seq('.', field('member', $.identifier)),
    // One bracket reads an index, or a slice when a range operator follows:
    // both begin with an expression, which is one decision too many for
    // two separate rules.
    index_selection: $ => seq(
      '[', field('index', $._expression),
      optional(seq(field('operator', choice('..', '..<')), field('upper', $._expression))),
      ']',
    ),
    declaration_reference: $ => seq(
      $.identifier, repeat($.member_selection),
    ),

    call_expression: $ => choice(
      prec(PREC.call, seq(
        field('function', $.indexed_expression), '(', optional($.arguments), ')',
      )),
      prec.dynamic(-2, prec.right(PREC.call, seq(
        field('function', $.indexed_expression), '(', optional($.arguments), ')',
        $.recovery_clause,
      ))),
    ),
    arguments: $ => commaSep1($._expression),
    recovery_clause: $ => seq(
      'else',
      choice(
        $._expression,
        seq('(', field('error', $.identifier), ')', optional($.block), 'end'),
      ),
    ),
    address_expression: $ => seq('addr', $.place),
    pointer_conversion: $ => seq('ptr', '(', $._expression, ')'),
    any_construction: $ => seq('any', '(', $._expression, ')'),
    empty_slice: _ => seq('[', ']'),
    measurement_expression: $ => choice(
      seq(choice('sizeof', 'alignof'), $._type),
      // `lenof` is contextual in the kernel: a declaration may also be named
      // lenof.  Keep the leading token an identifier and let highlight queries
      // apply an equality predicate instead of turning it into a keyword.
      seq(
        field('operator', $.identifier),
        field('value', choice($.identifier, seq('(', $.array_literal, ')'))),
      ),
    ),

    // `of` is contextual for the same reason as `lenof`: it remains a legal
    // identifier outside the few aggregate positions that give it meaning.
    of_keyword: $ => $.identifier,
    try_expression: $ => seq('try', choice($.call_expression, $.labeled_application)),

    identifier: _ => /[a-z][a-z0-9_]*|_[a-z0-9_]+/,
  },
});

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}

function binaryLevel($, precedence, operand, operators) {
  const operator = operators.length === 1 ? operators[0] : choice(...operators);
  return choice(
    prec.dynamic(1, operand),
    prec.dynamic(2, prec.left(precedence, seq(
      operand,
      repeat1(seq(field('operator', operator), operand)),
    ))),
  );
}
