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
- negotiated persistent key/string/shape table extensions

Per-message key/string/shape interning tables are message-local in Dynamic Profile and are not persistent session state unless a persistent table extension is negotiated.

Session state objects (`base_id`, `template_id`, dictionary ids) MUST NOT be reused across independent streams.

Session epochs SHOULD be treated as transport-local context and reset on reconnect unless explicitly negotiated.

Stateful wire forms require a negotiated transport/profile that defines state-reference discriminators, reset control encoding, dictionary ids, and retention rules. The v3 reference interoperability profile is stateless unless such a profile is negotiated. One such profile is the Twilic WebSocket Stateful Profile in section 9.

## 3. Stateful Forms

### 3.1 State patch

Delta payload against previous message or explicit base id.

Dynamic `state_patch` uses `0xDD`. Bound/Batch envelope `STATE_PATCH` uses `0x0A`.

Typical usage:

- hot object streams where changed-field ratio is low
- repeated schema emissions with minor updates

### 3.2 Template batch

Micro-batch reuse for repeated schema/shape bursts.

Dynamic `template_batch` uses `0xDE`. Bound/Batch envelope `TEMPLATE_BATCH` uses `0x0B`; `CONTROL_STREAM` uses `0x0C`, and `BASE_SNAPSHOT` uses `0x0D`.

Typical usage:

- short burst batches where full column mode is overkill
- repeated optional-field presence patterns

### 3.3 Bound and batch forms (`0x0F` / `0xDB` / `0xDC` / `0x0E`)

Bound streams, row batches, column batches, and schema-aware batches are available in session or stateless contexts.

Dynamic `row_batch`/`col_batch` use `0xDB`/`0xDC`. Envelope `BOUND_STREAM`/`SCHEMA_BATCH` use `0x0F`/`0x0E` and require explicit profile selection before byte interpretation.

- `BOUND_STREAM` (`0x0F`) is suitable when one shared schema is bound once and consecutive records can omit per-record schema/object envelopes
- `row_batch` is suitable for low-latency, moderate-size bursts
- `col_batch` is suitable for larger batches and column codec gains
- `SCHEMA_BATCH` (`0x0E`) is suitable when the same shared schema repeats and columnar gains are available

## 4. Reset Behavior

- `RESET_STATE`: invalidates all state references (bases/templates/dictionaries and negotiated persistent key/string/shape tables).

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

- v3 is a clean break from v2 for Bound Profile field/record-body payloads.
- Dynamic Profile may retain v2-compatible tags.
- Dual support requires explicit profile and version signaling outside payload decode heuristics.

## 8. Operational Recommendations

- Keep stateless fallback path always available.
- Log unknown reference failures with stream/session identifier.
- Apply bounded state retention and eviction policies.
- Monitor RESET_STATE frequency; frequent resets may indicate transport mismatch.
- For mixed deployments, gate v3 rollout behind explicit version negotiation.

## 9. Twilic WebSocket Stateful Profile

This section defines an explicit negotiated transport profile for Stateful Profile messages over WebSocket. Default WebSocket helpers remain stateless unless this profile is enabled (for example with `stateful: true`).

### 9.1 Session model

- One WebSocket connection carries two independent directional Twilic sessions: an outbound encoder session and an inbound decoder session.
- Encode state and decode state MUST NOT be shared across directions on the same connection.
- Session state starts empty when the WebSocket opens.
- Session state MUST NOT be inherited across reconnects. A new WebSocket is a new pair of directional sessions.

### 9.2 Message rules

- One WebSocket binary frame equals one Twilic message.
- Messages in each direction MUST be processed in order.
- The first message in a direction MUST be a full message that does not require prior session state.
- Subsequent messages in that direction MAY be full messages or `STATE_PATCH` messages.
- `RESET_STATE` invalidates that direction's session state on both peers and MUST NOT be delivered as an application value.
- After `RESET_STATE`, the next application message in that direction MUST be a full message before further stateful references.

### 9.3 Failure and recovery

- If decoding fails, decoder state MUST NOT partially advance.
- After reconnect, peers MUST start with empty directional sessions and bootstrap with a full message.
- Unknown references follow the configured unknown-reference policy (`fail-fast` or `stateless retry`).
