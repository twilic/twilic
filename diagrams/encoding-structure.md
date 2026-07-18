# Encoding Structure Diagram

This diagram shows how an encoder typically moves from baseline dynamic forms to more compact forms as repetition appears.

```mermaid
flowchart TD
    A[Input Value] --> B[Classify Root<br/>scalar / map / array]
    B --> C[SCALAR]
    B --> D[MAP or ARRAY]

    X[Shared schema<br/>single record] --> Y[SCHEMA_OBJECT]

    D --> E[Observe repetition<br/>keys / shape / type / value]
    E --> F[message-local<br/>key_ref / str_ref]
    E --> G[message-local<br/>shape_def]
    E --> H[TYPED_VECTOR<br/>homogeneous arrays]
    F --> I[compact dynamic refs]
    G --> I

    U[Shared schema<br/>record stream] --> V[BOUND_STREAM<br/>compact record bodies]

    J[Repeated rows<br/>same shape or schema] --> K[Batch decision<br/>row vs column]
    K --> L[ROW_BATCH]
    K --> M[COLUMN_BATCH]
    K --> M2[SCHEMA_BATCH]
    M --> N[Per-column codecs<br/>DELTA_* / FOR_BITPACK / RLE / DICTIONARY / XOR_FLOAT]
    M2 --> N

    O[Stateful session enabled] --> P[BASE_SNAPSHOT optional]
    P --> Q[STATE_PATCH<br/>previous or base refs]
    Q --> R[TEMPLATE_BATCH<br/>small bursts]
    R --> S[RESET_STATE on divergence]
    S --> T[Stateless full message fallback]
```

Notes:

- Message-local `shape_def`, `key_ref`, and `str_ref` drive compact dynamic reuse without persistent session state.
- Persistent CONTROL table updates require a separately negotiated stateful extension.
- `BOUND_STREAM` is preferred when a schema is bound once and records can omit per-record envelopes.
- `COLUMN_BATCH` becomes more effective as row count and column regularity increase.
- `SCHEMA_BATCH` is the preferred columnar form when every row shares a schema; `BOUND_STREAM` is the row-wise raw stream form.
- `STATE_PATCH` is beneficial only when sender and receiver state are synchronized.
