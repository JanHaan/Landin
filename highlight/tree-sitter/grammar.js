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
  selection: 11,
  call: 12,
};

module.exports = grammar({
  name: 'landin',

  word: $ => $.identifier,

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
    [$.declaration_reference, $.indexed_expression],
    [$._type, $.type_application],
    [$.routine_formals, $.parameters],
    [$.labeled_arguments, $.arguments],
    [$.function_declaration],
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
    [$.identifier_list, $.binding, $.type_declaration, $.concept_declaration, $.function_declaration],
  ],

  rules: {
    source_file: $ => seq(
      repeat($.import_declaration),
      repeat($._declaration),
    ),


    import_declaration: $ => seq('import', $.import_path),
    import_path: $ => seq($.identifier, repeat(seq('/', $.identifier))),

    _declaration: $ => choice(
      $.public_declaration,
      $.extern_declaration,
      $.conformance_declaration,
      $.fixed_conditional,
    ),

    public_declaration: $ => seq(
      optional('public'),
      choice(
        $.atom_declaration,
        $.binding,
        $.function_declaration,
        $.type_declaration,
        $.concept_declaration,
      ),
    ),

    extern_declaration: $ => seq(
      'extern', '(', field('convention', $.identifier), ')',
      field('name', $.identifier), ':', $.declared_signature,
    ),

    fixed_conditional: $ => seq(
      'fixed', 'if', field('condition', $._expression), 'then',
      repeat($._declaration),
      repeat(seq('elsif', field('condition', $._expression), 'then', repeat($._declaration))),
      optional(seq('else', repeat($._declaration))),
      'end', 'if',
    ),

    atom_declaration: $ => seq(field('name', $.identifier_list), ':', 'atom'),
    identifier_list: $ => seq($.identifier, repeat(seq(',', $.identifier))),

    binding: $ => choice(
      seq(
        optional('mut'),
        field('name', $.identifier),
        ':',
        field('type', $._type),
        optional(seq('=', field('value', $._expression))),
      ),
      seq(
        optional('mut'),
        field('name', $.identifier),
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

    function_type: $ => $.signature,
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
      'usize', 'isize', 'bool',
    ),

    type_declaration: $ => seq(
      field('name', $.identifier), ':', 'type',
      choice(
        seq('=', choice($.atom_union, $._type, $.struct_body)),
        seq($.type_formals, '=', choice($._type, $.struct_body)),
      ),
    ),

    concept_declaration: $ => seq(
      field('name', $.identifier), ':', 'type', '=', $.concept_body,
    ),
    concept_body: $ => seq(
      'concept', $.type_formals,
      optional(seq('is', commaSep1($.declaration_reference))),
      repeat($.concept_entry),
      'end', optional($.identifier),
    ),
    concept_entry: $ => seq(field('name', $.identifier), ':', $.signature),

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
      $.type_application,
      $.declaration_reference,
    ),
    conformance_argument: $ => seq(
      field('name', $.identifier), ':', field('value', $.argument_rhs),
    ),

    type_formals: $ => seq('(', commaSep1($.type_formal), ')'),
    type_formal: $ => choice(
      seq(
        field('name', $.identifier), ':', 'type',
        optional(seq('is', field('constraint', $.declaration_reference))),
      ),
      seq('fixed', field('name', $.identifier), ':', field('type', $._type)),
    ),

    atom_union: $ => seq(
      $.declaration_reference,
      '|',
      $.declaration_reference,
      repeat(seq('|', $.declaration_reference)),
    ),

    struct_body: $ => seq(
      'struct', repeat1(choice($.field, $.variant_part)), 'end', optional($.identifier),
    ),
    field: $ => seq(field('name', $.identifier), ':', field('type', $._type)),
    variant_part: $ => seq(
      field('name', $.identifier), ':', 'variant',
      $.variant_case, repeat(seq('|', $.variant_case)),
      'end', optional($.identifier),
    ),
    variant_case: $ => seq(
      field('name', $.identifier),
      optional(seq(':', '(', commaSep1($.field), ')')),
    ),

    function_declaration: $ => seq(
      field('name', $.identifier), ':',
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
    declared_signature: $ => seq(
      '(', optional($.routine_formals), ')', $.arrow, $.returns, optional($.errors),
    ),
    routine_formals: $ => commaSep1(choice($.parameter, $.type_formal)),
    parameters: $ => commaSep1($.parameter),
    parameter: $ => seq(
      optional('escaping'),
      optional($.parameter_convention),
      field('name', $.identifier), ':', field('type', $._type),
    ),
    parameter_convention: _ => choice('in', 'inout', 'sink'),
    returns: $ => choice(
      seq('(', optional(commaSep1($.named_return)), ')'),
      'none',
    ),
    named_return: $ => seq(
      field('name', $.identifier), ':', field('type', $._type),
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
    _statement: $ => prec.dynamic(3, choice(
      $._value_statement,
      $.call_expression,
      $.labeled_application,
      $.try_expression,
      $.if_expression,
      $.match_expression,
      $.bare_block,
    )),
    _value_statement: $ => prec.dynamic(5, choice(
      $.binding,
      $.destructuring_binding,
      $.assignment_statement,
      $.increment_statement,
      $.discard_statement,
      $.defer_statement,
      $.undo_statement,
      $.return_statement,
      $.fail_statement,
    )),

    destructuring_binding: $ => seq(
      '(', commaSep1($.destructured_field), ')', ':=', $._expression,
    ),
    destructured_field: $ => choice(
      '_',
      seq(field('name', $.identifier), optional(seq(':', choice($.identifier, '_')))),
    ),
    assignment_statement: $ => prec.right(100, seq(
      field('left', $.place), '=', field('right', $._expression),
    )),
    increment_statement: $ => seq(choice('inc', 'dec'), $.place),
    discard_statement: $ => seq('_', '=', $._expression),
    defer_statement: $ => seq('defer', $.call_expression),
    undo_statement: $ => seq('undo', $.call_expression),
    return_statement: $ => seq('return', optional(seq('when', $._expression))),
    fail_statement: $ => seq('fail', $._expression, optional(seq('when', $._expression))),

    if_expression: $ => prec.dynamic(4, prec.right(seq(
      'if', field('condition', $._expression), 'then', optional(field('consequence', $.block)),
      repeat(seq('elsif', field('condition', $._expression), 'then', optional(field('consequence', $.block)))),
      optional(seq('else', optional(field('alternative', $.block)))),
      'end', 'if',
    ))),
    match_expression: $ => prec.dynamic(4, seq(
      'match', field('value', $._expression), repeat1($.match_arm), 'end', 'match',
    )),
    match_arm: $ => seq(
      field('case', choice($.declaration_reference, '_')),
      optional(seq('(', commaSep1($.match_binding), ')')),
      ':', field('body', choice($._statement, $._expression)),
    ),
    match_binding: $ => seq(optional('inout'), field('name', $.identifier)),
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

    literal: $ => choice($.integer_literal, $.boolean_literal, $.zeroed_literal),
    boolean_literal: _ => choice('true', 'false'),
    zeroed_literal: _ => 'zeroed',
    integer_literal: _ => token(choice(
      /0[xX][0-9A-Fa-f][0-9A-Fa-f_]*/,
      /0[oO][0-7][0-7_]*/,
      /0[bB][01][01_]*/,
      /[0-9][0-9_]*/,
    )),

    array_literal: $ => prec.dynamic(4, seq('[', commaSep1($._expression), ']')),
    array_repetition: $ => choice(
      seq('[', $.integer_literal, $.of_keyword, $._expression, ']'),
      seq('[', $.of_keyword, $._expression, ']'),
      seq('[', commaSep1($._expression), ',', $.of_keyword, $._expression, ']'),
    ),
    struct_literal: $ => prec(50, seq(
      '(', commaSep1($.field_value), optional(seq(',', $.of_keyword, $._expression)), ')',
    )),
    field_value: $ => seq(field('name', $.identifier), ':', field('value', $._expression)),

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
    labeled_argument: $ => seq(field('name', $.identifier), ':', field('value', $.argument_rhs)),
    argument_rhs: $ => choice($._expression, $._type),

    indexed_expression: $ => choice(
      prec.dynamic(1, $.identifier),
      prec.dynamic(2, prec.left(PREC.selection, seq(
        $.identifier,
        repeat1(choice($.member_selection, $.index_selection, $.slice_selection)),
      ))),
    ),
    member_selection: $ => seq('.', field('member', $.identifier)),
    index_selection: $ => seq('[', field('index', $._expression), ']'),
    slice_selection: $ => seq(
      '[', field('lower', $._expression), field('operator', choice('..', '..<')),
      field('upper', $._expression), ']',
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
