# Shared fixtures

This directory contains deterministic, line-oriented interoperability corpora. The first corpus, `interop-v1.txt`, is generated from the Rust reference runtime and checked by the central Rust client adapter.

Fixtures are logical protocol cases encoded as wire bytes. Keep labels stable once published because language adapters use them to select the expected decoded value.
