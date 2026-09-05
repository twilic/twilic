#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "twilic/twilic.h"

#define TEST_ASSERT(cond, msg)                                                     \
  do {                                                                             \
    if (!(cond)) {                                                                 \
      fprintf(stderr, "assertion failed: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
      return 1;                                                                    \
    }                                                                              \
  } while (0)

#define TEST_RUN(name)                                                             \
  do {                                                                             \
    const int rc = name();                                                         \
    if (rc != 0) {                                                                 \
      fprintf(stderr, "test failed: %s\n", #name);                                 \
      return rc;                                                                   \
    }                                                                              \
  } while (0)

static inline void require_twilic_error_kind(const twilic_error_t *err, twilic_error_kind_t kind) {
  if (!err || err->kind != kind) {
    fprintf(stderr, "unexpected error kind: got %d want %d msg=%s\n", err ? (int)err->kind : -1,
            (int)kind, err ? err->msg : "(null)");
    exit(1);
  }
}

static inline int values_equal(const twilic_value_t *a, const twilic_value_t *b) {
  if (!a || !b || a->kind != b->kind) return 0;
  switch (a->kind) {
    case TWILIC_VALUE_NULL:
      return 1;
    case TWILIC_VALUE_BOOL:
      return a->bool_value == b->bool_value;
    case TWILIC_VALUE_I64:
      return a->i64 == b->i64;
    case TWILIC_VALUE_U64:
      return a->u64 == b->u64;
    case TWILIC_VALUE_F64:
      return a->f64 == b->f64;
    case TWILIC_VALUE_STRING:
      return (a->str == b->str) || (a->str && b->str && strcmp(a->str, b->str) == 0);
    case TWILIC_VALUE_BINARY:
      return a->bin_len == b->bin_len &&
             (a->bin_len == 0 || (a->bin && b->bin && memcmp(a->bin, b->bin, a->bin_len) == 0));
    case TWILIC_VALUE_ARRAY:
      if (a->arr_len != b->arr_len) return 0;
      for (size_t i = 0; i < a->arr_len; ++i) {
        if (!values_equal(&a->arr[i], &b->arr[i])) return 0;
      }
      return 1;
    case TWILIC_VALUE_MAP:
      if (a->map_len != b->map_len) return 0;
      for (size_t i = 0; i < a->map_len; ++i) {
        if ((a->map[i].key == b->map[i].key) ||
            (a->map[i].key && b->map[i].key && strcmp(a->map[i].key, b->map[i].key) == 0)) {
          if (!values_equal(&a->map[i].value, &b->map[i].value)) return 0;
        } else {
          return 0;
        }
      }
      return 1;
  }
  return 0;
}
