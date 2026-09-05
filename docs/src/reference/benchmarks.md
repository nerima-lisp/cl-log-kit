# Benchmarks

`benchmark/run.lisp` is a reproducible SBCL benchmark for `handle-log-record`
under representative payloads. It reports the minimum wall-clock time and the
bytes consed per call over several full-GC'd repetitions:

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-json-kit//:$(pwd)//:" \
  sbcl --script benchmark/run.lisp
```

## Results

`handle-log-record` allocates **zero bytes per call** on every benchmarked
wire format and payload. From one run on SBCL 2.6.0 / aarch64-darwin:

| Benchmark | ns/call | bytes/call |
| --- | --- | --- |
| `text-handler`, ASCII message + 3 fields | 392 | 0 |
| `json-handler`, ASCII message + 3 fields | 832 | 0 |
| `text-handler`, 256-char field value | 686 | 0 |
| `json-handler`, 256-char field value | 1787 | 0 |
| `json-handler`, double-float-heavy fields | 1227 | 0 |

Timings are machine-specific and will move on your hardware. The
`0 bytes/call` column is the part the test suite actually asserts, in
`t/performance-test.lisp`'s allocation-bound specs, so a change that
reintroduces per-call consing fails CI instead of regressing quietly.

## Comparison with log4cl

`benchmark/competitors.lisp` runs the same methodology against
[log4cl](https://github.com/sharplispers/log4cl), fetched via Quicklisp on
first run, writing an equivalent message and fields to a discarding stream.

On that same run `cl-log-kit` was roughly 1.3x slower in that minimal
configuration — 477 ns/call against log4cl's 370 ns/call, both
allocation-free.

The difference includes work that the compared log4cl path does not do. On
each call `cl-log-kit` escapes emitted tokens, writes a structured per-field
record, and performs the deep field snapshot, canonical-key deduplication,
reentrant stream serialization, and resource-limit checks described in
[Fields](../guide/fields.md) and [Handlers](../guide/handlers.md). log4cl writes one
already-formatted message string.
