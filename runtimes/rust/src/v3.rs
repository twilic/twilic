//! Twilic v3 Dynamic Profile entry points.
//!
//! v3 keeps the Dynamic tag table wire-compatible with v2 for unchanged tags.
//! The implementation reuses the dynamic codec while enforcing v3 canonical
//! integer and Twilic-PV shortest-form decode rules in the shared reader.

pub use crate::v2::{DEFAULT_MAX_DECODE_DEPTH, decode, encode};
