#include "twilic/errors.h"

namespace twilic {

TwilicError::TwilicError(TwilicErrorKind k, const std::string& what)
    : std::runtime_error(what), kind(k) {}

TwilicError unexpected_eof() {
  return TwilicError(TwilicErrorKind::ErrUnexpectedEof, "unexpected end of input");
}
TwilicError invalid_kind(uint8_t) {
  return TwilicError(TwilicErrorKind::ErrInvalidKind, "invalid message kind");
}
TwilicError invalid_tag(uint8_t) {
  return TwilicError(TwilicErrorKind::ErrInvalidTag, "invalid value tag");
}
TwilicError invalid_data(const std::string& msg) {
  return TwilicError(TwilicErrorKind::ErrInvalidData, msg);
}
TwilicError utf8_error() {
  return TwilicError(TwilicErrorKind::ErrUtf8, "utf8 decode error");
}
TwilicError unknown_reference(const std::string& ref_kind, uint64_t ref_id) {
  auto e = TwilicError(TwilicErrorKind::ErrUnknownReference, "unknown reference");
  e.ref_kind = ref_kind;
  e.ref_id = ref_id;
  return e;
}
TwilicError stateless_retry_required(const std::string& ref_kind, uint64_t ref_id) {
  auto e = TwilicError(TwilicErrorKind::ErrStatelessRetryRequired, "stateless retry required");
  e.ref_kind = ref_kind;
  e.ref_id = ref_id;
  return e;
}

}  // namespace twilic
