#include "test_helpers.h"

int main(void) {
  twilic_value_t value = twilic_null();
  twilic_value_free(&value);
  return 0;
}
