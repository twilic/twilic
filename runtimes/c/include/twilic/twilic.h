#ifndef TWILIC_H
#define TWILIC_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "twilic/version.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  TWILIC_VALUE_NULL = 0,
  TWILIC_VALUE_BOOL,
  TWILIC_VALUE_I64,
  TWILIC_VALUE_U64,
  TWILIC_VALUE_F64,
  TWILIC_VALUE_STRING,
  TWILIC_VALUE_BINARY,
  TWILIC_VALUE_ARRAY,
  TWILIC_VALUE_MAP,
} twilic_value_kind_t;

typedef struct twilic_map_entry twilic_map_entry_t;

typedef struct twilic_value {
  twilic_value_kind_t kind;
  bool bool_value;
  int64_t i64;
  uint64_t u64;
  double f64;
  char *str;
  uint8_t *bin;
  size_t bin_len;
  struct twilic_value *arr;
  size_t arr_len;
  twilic_map_entry_t *map;
  size_t map_len;
} twilic_value_t;

struct twilic_map_entry {
  char *key;
  twilic_value_t value;
};

typedef struct twilic_schema_field {
  int number;
  char *name;
  char *logical_type;
  bool required;
  char **enum_values;
  size_t enum_values_len;
} twilic_schema_field_t;

typedef struct twilic_schema {
  uint64_t schema_id;
  char *name;
  twilic_schema_field_t *fields;
  size_t fields_len;
} twilic_schema_t;

typedef struct {
  uint8_t *data;
  size_t len;
} twilic_buffer_t;

typedef enum {
  TWILIC_ERR_UNEXPECTED_EOF = 0,
  TWILIC_ERR_INVALID_KIND,
  TWILIC_ERR_INVALID_TAG,
  TWILIC_ERR_INVALID_DATA,
  TWILIC_ERR_UTF8,
  TWILIC_ERR_UNKNOWN_REFERENCE,
  TWILIC_ERR_STATELESS_RETRY_REQUIRED,
} twilic_error_kind_t;

typedef struct {
  twilic_error_kind_t kind;
  uint8_t byte;
  char msg[256];
  char ref_kind[64];
  uint64_t ref_id;
} twilic_error_t;

twilic_value_t twilic_null(void);
twilic_value_t twilic_bool(bool value);
twilic_value_t twilic_i64(int64_t value);
twilic_value_t twilic_u64(uint64_t value);
twilic_value_t twilic_f64(double value);
twilic_value_t twilic_string(const char *value);
twilic_value_t twilic_binary(const uint8_t *data, size_t len);
twilic_value_t twilic_array(twilic_value_t *items, size_t count);
twilic_value_t twilic_map(twilic_map_entry_t *entries, size_t count);
twilic_map_entry_t twilic_entry(const char *key, twilic_value_t value);

void twilic_value_free(twilic_value_t *value);
void twilic_buffer_free(twilic_buffer_t *buffer);

int twilic_encode(const twilic_value_t *value, twilic_buffer_t *out, twilic_error_t *err);
int twilic_decode(const uint8_t *data, size_t len, twilic_value_t *out, twilic_error_t *err);
int twilic_encode_with_schema(const twilic_schema_t *schema, const twilic_value_t *value,
                              twilic_buffer_t *out, twilic_error_t *err);
int twilic_encode_batch(const twilic_value_t *values, size_t count, twilic_buffer_t *out,
                        twilic_error_t *err);

#ifdef __cplusplus
}
#endif

#endif
