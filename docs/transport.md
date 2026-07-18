# Transport Guide (v3)

This document describes transport and session behavior for Twilic v3.

## 1. Stateless vs Stateful

- Stateless mode: every message is self-sufficient.
- Stateful mode: messages may reference prior session state (`base_id`, templates, dictionaries).

When transport guarantees are weak, encoder SHOULD remain stateless or use stateless retry policy.

Recommended default for general HTTP/queue usage is stateless mode.

## 2. Session State

Session state may include:

- base snapshots
- templates
- optional dictionary metadata

Per-message key/string/shape interning tables are message-local in Dynamic Profile and are not persistent session state.

Session state objects (`base_id`, `template_id`, dictionary ids) MUST NOT be reused across independent streams.

Session epochs SHOULD be treated as transport-local context and reset on reconnect unless explicitly negotiated.

## 3. Stateful Forms

### 3.1 `state_patch` (`0xDD`)

Delta payload against previous message or explicit base id.

Typical usage:

- hot object streams where changed-field ratio is low
- repeated schema emissions with minor updates

### 3.2 `template_batch` (`0xDE`)

Micro-batch reuse for repeated schema/shape bursts.

Typical usage:

- short burst batches where full column mode is overkill
- repeated optional-field presence patterns

### 3.3 Bound and batch forms (`0x0F` / `0xDB` / `0xDC` / `0x0E`)

Bound streams, row batches, column batches, and schema-aware batches are available in session or stateless contexts.

- `bound_stream` (`0x0F`) is suitable when one shared schema is bound once and consecutive records can omit per-record schema/object envelopes
- `row_batch` is suitable for low-latency, moderate-size bursts
- `col_batch` is suitable for larger batches and column codec gains
- `schema_batch` (`0x0E`) is suitable when the same shared schema repeats and is the primary comparison point against Protobuf repeated records and Avro raw streams

## 4. Reset Behavior

- `RESET_STATE`: invalidates all state references (bases/templates/dictionaries).

After `RESET_STATE`, both sides MUST treat old state ids as invalid.

After reset, sender should emit a stateless full frame or fresh base/template registration before sending further stateful references.

## 5. Unknown Reference Policy

Decoder policy MUST be fixed per deployment:

- fail-fast
- stateless retry

Unknown ids MUST NOT be silently accepted.

`stateless retry` means transport/application requests a stateless resend; it does not mean speculative local repair.

## 6. Ordering and Reliability

Stateful mode requires:

- ordered delivery for state-mutating frames
- no silent drop of reset or base/template registration frames
- bounded retention window alignment between peers

If the transport cannot provide these, stateful forms SHOULD be disabled.

Out-of-order delivery without reordering buffers can corrupt stateful decode expectations.

## 7. Versioning

- v3 is a clean break from v2 for Bound Profile field payloads.
- Dynamic Profile may retain v2-compatible tags.
- Dual support requires explicit profile and version signaling outside payload decode heuristics.

## 8. Operational Recommendations

- Keep stateless fallback path always available.
- Log unknown reference failures with stream/session identifier.
- Apply bounded state retention and eviction policies.
- Monitor RESET_STATE frequency; frequent resets may indicate transport mismatch.
- For mixed deployments, gate v3 rollout behind explicit version negotiation.
