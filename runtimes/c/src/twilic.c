#include "twilic/twilic.h"

#include <cstring>
#include <string>
#include <vector>

#include "twilic/model.h"
#include "twilic/errors.h"
#include "twilic/protocol.h"
#include "twilic/v2.h"

namespace {

using namespace twilic;

static void set_error(twilic_error_t *err, const TwilicError &ex) {
  if (!err) return;
  switch (ex.kind) {
    case TwilicErrorKind::ErrUnexpectedEof:
      err->kind = TWILIC_ERR_UNEXPECTED_EOF;
      break;
    case TwilicErrorKind::ErrInvalidKind:
      err->kind = TWILIC_ERR_INVALID_KIND;
      break;
    case TwilicErrorKind::ErrInvalidTag:
      err->kind = TWILIC_ERR_INVALID_TAG;
      break;
    case TwilicErrorKind::ErrInvalidData:
      err->kind = TWILIC_ERR_INVALID_DATA;
      break;
    case TwilicErrorKind::ErrUtf8:
      err->kind = TWILIC_ERR_UTF8;
      break;
    case TwilicErrorKind::ErrUnknownReference:
      err->kind = TWILIC_ERR_UNKNOWN_REFERENCE;
      break;
    case TwilicErrorKind::ErrStatelessRetryRequired:
      err->kind = TWILIC_ERR_STATELESS_RETRY_REQUIRED;
      break;
  }
  err->byte = ex.byte;
  std::snprintf(err->msg, sizeof(err->msg), "%s", ex.what());
  std::snprintf(err->ref_kind, sizeof(err->ref_kind), "%s", ex.ref_kind.c_str());
  err->ref_id = ex.ref_id;
}

static char *dup_cstr(const std::string &s) {
  char *out = static_cast<char *>(std::malloc(s.size() + 1));
  if (!out) return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

static Value to_cpp_value(const twilic_value_t *value);
static twilic_value_t from_cpp_value(const Value &value);

static Value to_cpp_value(const twilic_value_t *value) {
  if (!value) return new_null();
  switch (value->kind) {
    case TWILIC_VALUE_NULL:
      return new_null();
    case TWILIC_VALUE_BOOL:
      return new_bool(value->bool_value);
    case TWILIC_VALUE_I64:
      return new_i64(value->i64);
    case TWILIC_VALUE_U64:
      return new_u64(value->u64);
    case TWILIC_VALUE_F64:
      return new_f64(value->f64);
    case TWILIC_VALUE_STRING:
      return new_string(value->str ? value->str : "");
    case TWILIC_VALUE_BINARY: {
      std::vector<uint8_t> bin;
      if (value->bin && value->bin_len > 0) {
        bin.assign(value->bin, value->bin + value->bin_len);
      }
      return new_binary(bin);
    }
    case TWILIC_VALUE_ARRAY: {
      std::vector<Value> items;
      if (value->arr && value->arr_len > 0) {
        items.reserve(value->arr_len);
        for (size_t i = 0; i < value->arr_len; ++i) items.push_back(to_cpp_value(&value->arr[i]));
      }
      return new_array(std::move(items));
    }
    case TWILIC_VALUE_MAP: {
      std::vector<MapEntry> entries;
      if (value->map && value->map_len > 0) {
        entries.reserve(value->map_len);
        for (size_t i = 0; i < value->map_len; ++i) {
          entries.push_back(entry(value->map[i].key ? value->map[i].key : "", to_cpp_value(&value->map[i].value)));
        }
      }
      return new_map(std::move(entries));
    }
  }
  return new_null();
}

static twilic_value_t from_cpp_value(const Value &value) {
  twilic_value_t out{};
  switch (value.kind) {
    case ValueKind::Null:
      out.kind = TWILIC_VALUE_NULL;
      return out;
    case ValueKind::Bool:
      out.kind = TWILIC_VALUE_BOOL;
      out.bool_value = value.bool_value;
      return out;
    case ValueKind::I64:
      out.kind = TWILIC_VALUE_I64;
      out.i64 = value.i64;
      return out;
    case ValueKind::U64:
      out.kind = TWILIC_VALUE_U64;
      out.u64 = value.u64;
      return out;
    case ValueKind::F64:
      out.kind = TWILIC_VALUE_F64;
      out.f64 = value.f64;
      return out;
    case ValueKind::String:
      out.kind = TWILIC_VALUE_STRING;
      out.str = dup_cstr(value.str);
      return out;
    case ValueKind::Binary:
      out.kind = TWILIC_VALUE_BINARY;
      out.bin_len = value.bin.size();
      if (out.bin_len > 0) {
        out.bin = static_cast<uint8_t *>(std::malloc(out.bin_len));
        if (out.bin) std::memcpy(out.bin, value.bin.data(), out.bin_len);
      }
      return out;
    case ValueKind::Array:
      out.kind = TWILIC_VALUE_ARRAY;
      out.arr_len = value.arr.size();
      if (out.arr_len > 0) {
        out.arr = static_cast<twilic_value_t *>(std::calloc(out.arr_len, sizeof(twilic_value_t)));
        if (out.arr) {
          for (size_t i = 0; i < out.arr_len; ++i) out.arr[i] = from_cpp_value(value.arr[i]);
        }
      }
      return out;
    case ValueKind::Map:
      out.kind = TWILIC_VALUE_MAP;
      out.map_len = value.map.size();
      if (out.map_len > 0) {
        out.map = static_cast<twilic_map_entry_t *>(std::calloc(out.map_len, sizeof(twilic_map_entry_t)));
        if (out.map) {
          for (size_t i = 0; i < out.map_len; ++i) {
            out.map[i].key = dup_cstr(value.map[i].key);
            out.map[i].value = from_cpp_value(value.map[i].value);
          }
        }
      }
      return out;
  }
  out.kind = TWILIC_VALUE_NULL;
  return out;
}

static Schema to_cpp_schema(const twilic_schema_t *schema) {
  Schema out{};
  if (!schema) return out;
  out.schema_id = schema->schema_id;
  if (schema->name) out.name = schema->name;
  if (schema->fields && schema->fields_len > 0) {
    out.fields.reserve(schema->fields_len);
    for (size_t i = 0; i < schema->fields_len; ++i) {
      SchemaField f{};
      f.number = schema->fields[i].number;
      if (schema->fields[i].name) f.name = schema->fields[i].name;
      if (schema->fields[i].logical_type) f.logical_type = schema->fields[i].logical_type;
      f.required = schema->fields[i].required;
      if (schema->fields[i].enum_values && schema->fields[i].enum_values_len > 0) {
        for (size_t j = 0; j < schema->fields[i].enum_values_len; ++j) {
          if (schema->fields[i].enum_values[j]) f.enum_values.emplace_back(schema->fields[i].enum_values[j]);
        }
      }
      out.fields.push_back(std::move(f));
    }
  }
  return out;
}

static int write_buffer(const std::vector<uint8_t> &bytes, twilic_buffer_t *out, twilic_error_t *err) {
  if (!out) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "output buffer is null");
    }
    return -1;
  }
  out->len = bytes.size();
  out->data = nullptr;
  if (out->len == 0) return 0;
  out->data = static_cast<uint8_t *>(std::malloc(out->len));
  if (!out->data) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "allocation failed");
    }
    out->len = 0;
    return -1;
  }
  std::memcpy(out->data, bytes.data(), out->len);
  return 0;
}

}  // namespace

extern "C" {

twilic_value_t twilic_null(void) { return from_cpp_value(new_null()); }

twilic_value_t twilic_bool(bool value) { return from_cpp_value(new_bool(value)); }

twilic_value_t twilic_i64(int64_t value) { return from_cpp_value(new_i64(value)); }

twilic_value_t twilic_u64(uint64_t value) { return from_cpp_value(new_u64(value)); }

twilic_value_t twilic_f64(double value) { return from_cpp_value(new_f64(value)); }

twilic_value_t twilic_string(const char *value) { return from_cpp_value(new_string(value ? value : "")); }

twilic_value_t twilic_binary(const uint8_t *data, size_t len) {
  std::vector<uint8_t> bin;
  if (data && len > 0) bin.assign(data, data + len);
  return from_cpp_value(new_binary(bin));
}

twilic_value_t twilic_array(twilic_value_t *items, size_t count) {
  std::vector<Value> values;
  if (items && count > 0) {
    values.reserve(count);
    for (size_t i = 0; i < count; ++i) values.push_back(to_cpp_value(&items[i]));
  }
  return from_cpp_value(new_array(std::move(values)));
}

twilic_map_entry_t twilic_entry(const char *key, twilic_value_t value) {
  twilic_map_entry_t entry{};
  entry.key = dup_cstr(key ? key : "");
  entry.value = value;
  return entry;
}

twilic_value_t twilic_map(twilic_map_entry_t *entries, size_t count) {
  std::vector<MapEntry> items;
  if (entries && count > 0) {
    items.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      items.push_back(twilic::entry(entries[i].key ? entries[i].key : "", to_cpp_value(&entries[i].value)));
    }
  }
  return from_cpp_value(new_map(std::move(items)));
}

void twilic_value_free(twilic_value_t *value) {
  if (!value) return;
  switch (value->kind) {
    case TWILIC_VALUE_STRING:
      std::free(value->str);
      value->str = nullptr;
      break;
    case TWILIC_VALUE_BINARY:
      std::free(value->bin);
      value->bin = nullptr;
      value->bin_len = 0;
      break;
    case TWILIC_VALUE_ARRAY:
      if (value->arr) {
        for (size_t i = 0; i < value->arr_len; ++i) twilic_value_free(&value->arr[i]);
        std::free(value->arr);
        value->arr = nullptr;
      }
      value->arr_len = 0;
      break;
    case TWILIC_VALUE_MAP:
      if (value->map) {
        for (size_t i = 0; i < value->map_len; ++i) {
          std::free(value->map[i].key);
          twilic_value_free(&value->map[i].value);
        }
        std::free(value->map);
        value->map = nullptr;
      }
      value->map_len = 0;
      break;
    default:
      break;
  }
  value->kind = TWILIC_VALUE_NULL;
}

void twilic_buffer_free(twilic_buffer_t *buffer) {
  if (!buffer) return;
  std::free(buffer->data);
  buffer->data = nullptr;
  buffer->len = 0;
}

int twilic_encode(const twilic_value_t *value, twilic_buffer_t *out, twilic_error_t *err) {
  try {
    const auto cpp = to_cpp_value(value);
    return write_buffer(encode_v2(cpp), out, err);
  } catch (const TwilicError &ex) {
    set_error(err, ex);
    return -1;
  } catch (const std::exception &ex) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "%s", ex.what());
    }
    return -1;
  }
}

int twilic_decode(const uint8_t *data, size_t len, twilic_value_t *out, twilic_error_t *err) {
  if (!out) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "output value is null");
    }
    return -1;
  }
  try {
    const std::vector<uint8_t> bytes(data, data + len);
    *out = from_cpp_value(decode_v2(bytes));
    return 0;
  } catch (const TwilicError &ex) {
    set_error(err, ex);
    return -1;
  } catch (const std::exception &ex) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "%s", ex.what());
    }
    return -1;
  }
}

int twilic_encode_with_schema(const twilic_schema_t *schema, const twilic_value_t *value,
                              twilic_buffer_t *out, twilic_error_t *err) {
  try {
    SessionEncoder enc;
    const auto cpp = to_cpp_value(value);
    return write_buffer(enc.encode_with_schema(to_cpp_schema(schema), cpp), out, err);
  } catch (const TwilicError &ex) {
    set_error(err, ex);
    return -1;
  } catch (const std::exception &ex) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "%s", ex.what());
    }
    return -1;
  }
}

int twilic_encode_batch(const twilic_value_t *values, size_t count, twilic_buffer_t *out, twilic_error_t *err) {
  try {
    SessionEncoder enc;
    std::vector<Value> items;
    if (values && count > 0) {
      items.reserve(count);
      for (size_t i = 0; i < count; ++i) items.push_back(to_cpp_value(&values[i]));
    }
    return write_buffer(enc.encode_batch(items), out, err);
  } catch (const TwilicError &ex) {
    set_error(err, ex);
    return -1;
  } catch (const std::exception &ex) {
    if (err) {
      err->kind = TWILIC_ERR_INVALID_DATA;
      std::snprintf(err->msg, sizeof(err->msg), "%s", ex.what());
    }
    return -1;
  }
}

}  // extern "C"
