#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>

namespace twilic {

enum class TwilicErrorKind {
  ErrUnexpectedEof,
  ErrInvalidKind,
  ErrInvalidTag,
  ErrInvalidData,
  ErrUtf8,
  ErrUnknownReference,
  ErrStatelessRetryRequired,
};

struct TwilicError : std::runtime_error {
  TwilicErrorKind kind;
  uint8_t byte{};
  std::string msg;
  std::string ref_kind;
  uint64_t ref_id{};
  TwilicError(TwilicErrorKind k, const std::string& what);
};

TwilicError unexpected_eof();
TwilicError invalid_kind(uint8_t b);
TwilicError invalid_tag(uint8_t b);
TwilicError invalid_data(const std::string& msg);
TwilicError utf8_error();
TwilicError unknown_reference(const std::string& ref_kind, uint64_t ref_id);
TwilicError stateless_retry_required(const std::string& ref_kind, uint64_t ref_id);

}  // namespace twilic
