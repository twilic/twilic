//! Run with `cargo bench --bench integer_vectors`. No external benchmark dependencies.
use std::{
    hint::black_box,
    time::{Duration, Instant},
};
use twilic::{
    codec::{encode_i64_vector, encode_u64_vector},
    model::VectorCodec,
};

fn measure(mut encode: impl FnMut(&mut Vec<u8>)) -> (f64, usize) {
    // Reuse the destination so the measurement includes codec scratch allocations,
    // but excludes allocation of the caller's output buffer.
    let mut out = Vec::new();
    for _ in 0..1_000 {
        out.clear();
        encode(&mut out);
        black_box(&out);
    }
    let mut samples = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let mut iterations = 0u64;
        loop {
            for _ in 0..100 {
                out.clear();
                encode(&mut out);
                black_box(&out);
            }
            iterations += 100;
            if start.elapsed() >= Duration::from_millis(100) {
                break;
            }
        }
        samples.push(start.elapsed().as_nanos() as f64 / iterations as f64);
    }
    samples.sort_by(f64::total_cmp);
    (samples[2], out.len())
}

fn main() {
    // Cargo also invokes harness-free benches under `test --all-targets`.
    if !std::env::args().any(|arg| arg == "--bench") {
        return;
    }
    println!("codec,count,median_ns,bytes");
    for count in [4, 256, 4096] {
        let values: Vec<i64> = (0..count)
            .map(|i| 1_000_000 + i as i64 * 10 + (i % 7) as i64)
            .collect();
        for codec in [
            VectorCodec::DirectBitpack,
            VectorCodec::DeltaBitpack,
            VectorCodec::ForBitpack,
            VectorCodec::DeltaForBitpack,
            VectorCodec::DeltaDeltaBitpack,
        ] {
            let (ns, bytes) =
                measure(|out| encode_i64_vector(black_box(&values), black_box(codec), out));
            println!("i64_{codec:?},{count},{ns:.2},{bytes}");
        }
        let unsigned: Vec<u64> = values.iter().map(|v| *v as u64).collect();
        for codec in [VectorCodec::DirectBitpack, VectorCodec::ForBitpack] {
            let (ns, bytes) =
                measure(|out| encode_u64_vector(black_box(&unsigned), black_box(codec), out));
            println!("u64_{codec:?},{count},{ns:.2},{bytes}");
        }
    }
}
