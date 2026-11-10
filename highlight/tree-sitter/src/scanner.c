#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stddef.h>
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

/* The opener has already been consumed.  At each position the compiler
   tests a complete delimiter, otherwise it advances one character.  With
   LEFT, every character read is taken from it, and false is returned once
   it is spent. */
static bool block_comment_within(TSLexer *lexer, unsigned *left) {
  unsigned depth = 1;
  unsigned dashes = 0;
  while (lexer->lookahead != 0 && depth != 0) {
    int32_t c = lexer->lookahead;
    if (left != NULL) {
      if (*left < 3) return false;
      *left -= 3;
    }
    advance(lexer);
    if (c == '-') {
      if (dashes < 2) dashes++;
    } else {
      if (c == '(' && dashes == 2) depth++;
      dashes = 0;
      if (c == ')') {
        if (lexer->lookahead == '-') {
          advance(lexer);
          if (lexer->lookahead == '-') {
            advance(lexer);
            depth--;
          } else {
            dashes = 1;
          }
        }
      }
    }
  }
  return true;
}

static void block_comment(TSLexer *lexer) {
  (void)block_comment_within(lexer, NULL);
}

/* How many characters the look-ahead for a destructuring binding may read.
   A pattern is a few names.  Unbounded, a `(` that is never closed read to
   the end of the file, and in error recovery, where every external token
   is offered, so did each later line that begins with one: a file of such
   lines took a scan of the rest of the file for every one of them. */
#define DESTRUCTURING_LOOKAHEAD 4096

static bool look(TSLexer *lexer, unsigned *left) {
  if (*left == 0) return false;
  (*left)--;
  advance(lexer);
  return true;
}

/* [1750]: a `(` that begins a line, and whose matching `)` is followed by
   `:=`, begins a destructuring binding rather than a call of the line above.
   The token is the `(` alone; what follows it is only looked at, and no
   further than DESTRUCTURING_LOOKAHEAD: a pattern longer than that is not
   recognised as one. */
static bool destructuring_follows(TSLexer *lexer) {
  unsigned depth = 1;
  unsigned left = DESTRUCTURING_LOOKAHEAD;
  while (lexer->lookahead != 0) {
    int32_t c = lexer->lookahead;
    if (c == '"') {
      if (!look(lexer, &left)) return false;
      while (lexer->lookahead != 0 && lexer->lookahead != '"' &&
             lexer->lookahead != '\n') {
        if (lexer->lookahead == '\\' && !look(lexer, &left)) return false;
        if (!look(lexer, &left)) return false;
      }
      if (lexer->lookahead == '"' && !look(lexer, &left)) return false;
      continue;
    }
    if (c == '-') {
      if (!look(lexer, &left)) return false;
      if (lexer->lookahead == '-') {
        if (!look(lexer, &left)) return false;
        if (lexer->lookahead == '(') {
          if (!look(lexer, &left)) return false;
          if (!block_comment_within(lexer, &left)) return false;
        } else {
          while (lexer->lookahead != 0 && lexer->lookahead != '\n' &&
                 lexer->lookahead != '\r') {
            if (!look(lexer, &left)) return false;
          }
        }
      }
      continue;
    }
    if (!look(lexer, &left)) return false;
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      if (--depth == 0) break;
    }
  }
  if (depth != 0) return false;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\r' || lexer->lookahead == '\n') {
    if (!look(lexer, &left)) return false;
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
      block_comment(lexer);
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
