#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>

enum TokenType {
  COMMENT,
  MINUS,
  ARROW,
  MINUS_PERCENT,
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

bool tree_sitter_landin_external_scanner_scan(void *payload, TSLexer *lexer,
                                              const bool *valid_symbols) {
  (void)payload;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\r' || lexer->lookahead == '\n') {
    skip(lexer);
  }
  if (lexer->lookahead != '-') return false;
  advance(lexer);

  if (lexer->lookahead == '>' && valid_symbols[ARROW]) {
    advance(lexer);
    lexer->mark_end(lexer);
    lexer->result_symbol = ARROW;
    return true;
  }

  if (lexer->lookahead == '%' && valid_symbols[MINUS_PERCENT]) {
    advance(lexer);
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
