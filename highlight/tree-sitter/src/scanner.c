#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>

enum TokenType {
  COMMENT,
  MINUS,
  ARROW,
  MINUS_PERCENT,
  MINUS_EQUALS,
  MINUS_PERCENT_EQUALS,
  DESTRUCTURING_OPEN,
};

void *tree_sitter_landin_external_scanner_create(void) { return NULL; }
void tree_sitter_landin_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_landin_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}
void tree_sitter_landin_external_scanner_deserialize(void *payload,
                                                     const char *buffer,
                                                     unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }
static void skip(TSLexer *lexer) { lexer->advance(lexer, true); }

/* [1750]: a `(` that begins a line, and whose matching `)` is followed by
   `:=`, begins a destructuring binding rather than a call of the line above.
   The token is the `(` alone; what follows it is only looked at. */
static bool destructuring_follows(TSLexer *lexer) {
  unsigned depth = 1;
  while (lexer->lookahead != 0) {
    int32_t c = lexer->lookahead;
    if (c == '"') {
      advance(lexer);
      while (lexer->lookahead != 0 && lexer->lookahead != '"' &&
             lexer->lookahead != '\n') {
        if (lexer->lookahead == '\\') advance(lexer);
        advance(lexer);
      }
      if (lexer->lookahead == '"') advance(lexer);
      continue;
    }
    if (c == '-') {
      advance(lexer);
      if (lexer->lookahead == '-') {
        while (lexer->lookahead != 0 && lexer->lookahead != '\n') {
          advance(lexer);
        }
      }
      continue;
    }
    advance(lexer);
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      if (--depth == 0) break;
    }
  }
  if (depth != 0) return false;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\r' || lexer->lookahead == '\n') {
    advance(lexer);
  }
  if (lexer->lookahead != ':') return false;
  advance(lexer);
  return lexer->lookahead == '=';
}

bool tree_sitter_landin_external_scanner_scan(void *payload, TSLexer *lexer,
                                              const bool *valid_symbols) {
  (void)payload;
  bool line_began = lexer->get_column(lexer) == 0;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\r' || lexer->lookahead == '\n') {
    if (lexer->lookahead == '\n' || lexer->lookahead == '\r') {
      line_began = true;
    }
    skip(lexer);
  }
  if (lexer->lookahead == '(' && line_began &&
      valid_symbols[DESTRUCTURING_OPEN]) {
    advance(lexer);
    lexer->mark_end(lexer);
    if (destructuring_follows(lexer)) {
      lexer->result_symbol = DESTRUCTURING_OPEN;
      return true;
    }
    return false;
  }
  if (lexer->lookahead != '-') return false;
  advance(lexer);

  if (lexer->lookahead == '>' && valid_symbols[ARROW]) {
    advance(lexer);
    lexer->mark_end(lexer);
    lexer->result_symbol = ARROW;
    return true;
  }

  if (lexer->lookahead == '=' && valid_symbols[MINUS_EQUALS]) {
    advance(lexer);
    lexer->mark_end(lexer);
    lexer->result_symbol = MINUS_EQUALS;
    return true;
  }
  if (lexer->lookahead == '%' &&
      (valid_symbols[MINUS_PERCENT] || valid_symbols[MINUS_PERCENT_EQUALS])) {
    advance(lexer);
    if (lexer->lookahead == '=' && valid_symbols[MINUS_PERCENT_EQUALS]) {
      advance(lexer);
      lexer->mark_end(lexer);
      lexer->result_symbol = MINUS_PERCENT_EQUALS;
      return true;
    }
    if (!valid_symbols[MINUS_PERCENT]) return false;
    lexer->mark_end(lexer);
    lexer->result_symbol = MINUS_PERCENT;
    return true;
  }

  if (lexer->lookahead == '-') {
    if (!valid_symbols[COMMENT]) return false;
    advance(lexer);
    if (lexer->lookahead == '(') {
      advance(lexer);
      unsigned depth = 1;
      while (lexer->lookahead != 0) {
        if (lexer->lookahead == '-') {
          advance(lexer);
          if (lexer->lookahead == '-') {
            advance(lexer);
            if (lexer->lookahead == '(') {
              advance(lexer);
              depth++;
            }
          }
        } else if (lexer->lookahead == ')') {
          advance(lexer);
          if (lexer->lookahead == '-') {
            advance(lexer);
            if (lexer->lookahead == '-') {
              advance(lexer);
              if (--depth == 0) {
                lexer->mark_end(lexer);
                lexer->result_symbol = COMMENT;
                return true;
              }
            }
          }
        } else {
          advance(lexer);
        }
      }
      lexer->mark_end(lexer);
      lexer->result_symbol = COMMENT;
      return true;
    }

    while (lexer->lookahead != 0 && lexer->lookahead != '\n' &&
           lexer->lookahead != '\r') {
      advance(lexer);
    }
    lexer->mark_end(lexer);
    lexer->result_symbol = COMMENT;
    return true;
  }

  if (!valid_symbols[MINUS]) return false;
  lexer->mark_end(lexer);
  lexer->result_symbol = MINUS;
  return true;
}
