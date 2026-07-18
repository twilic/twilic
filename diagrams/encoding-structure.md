# Encoding Structure Diagram

This diagram shows how an encoder typically moves from baseline dynamic forms to more compact forms as repetition appears.

```mermaid
flowchart TD
    A[Input Value] --> B[Classify Root<br/>scalar / map / array]
    B --> C[SCALAR]
    B --> D[MAP or ARRAY]

    D --> E[Observe repetition<br/>keys / shape / type / value]
    E --> F[CONTROL REGISTER_KEYS]
    E --> G[CONTROL REGISTER_SHAPE]
    E --> H[TYPED_VECTOR<br/>homogeneous arrays]
    F --> I[SHAPED_OBJECT]
    G --> I

    U[Shared schema<br/>record stream] --> V[BOUND_STREAM<br/>compact record bodies]

    J[Repeated rows<br/>same shape or schema] --> K[Batch decision<br/>row vs column]
    K --> L[ROW_BATCH]
    K --> M[COLUMN_BATCH]
    K --> M2[SCHEMA_BATCH]
    M --> N[Per-column codecs<br/>delta / FOR / RLE / dictionary / XOR]
    M2 --> N

    O[Stateful session enabled] --> P[BASE_SNAPSHOT optional]
    P --> Q[STATE_PATCH<br/>previous or base refs]
    Q --> R[TEMPLATE_BATCH<br/>small bursts]
    R --> S[RESET_STATE on divergence]
    S --> T[Stateless full message fallback]
```

Notes:

- `CONTROL` updates drive promotion to compact ids (`key_id`, `shape_id`, `string_id`).
- `BOUND_STREAM` is preferred when a schema is bound once and records can omit per-record envelopes.
- `COLUMN_BATCH` becomes more effective as row count and column regularity increase.
- `SCHEMA_BATCH` is the preferred form when every row shares a schema and is the primary compact batch for Protobuf/Avro comparisons.
- `STATE_PATCH` is beneficial only when sender and receiver state are synchronized.
