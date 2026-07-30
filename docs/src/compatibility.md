# Compatibility

## Supported environment

SBCL only, on the platforms the flake builds: `x86_64-linux` and
`aarch64-darwin`.

The library uses `sb-thread`, `sb-gray`, `sb-ext`, and `sb-debug` directly
for its locking, bounded output streams, atomics, and backtrace capture, so
it is deliberately not portable Common Lisp. The shipped `cl-log-kit` system
otherwise depends on ASDF 3.3.1 or newer and three nerima-lisp toolkit
packages used directly with no adapter layer: `cl-date-kit` (calendar/zone
handling), `cl-concurrent-kit` (locking/atomics), and `cl-host-kit`
(filesystem operations). See `cl-log-kit.asd` for exact version floors.

## Stability promise

The exported surface is versioned under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Anything that
changes the shape or behavior of an exported symbol gets a major version and
a `### Breaking Changes` section in the [changelog](changelog.md) with an
explicit migration path. Every behavior change is recorded there under the
version it shipped in.

Every exported symbol carries a docstring, so `(documentation 'log-info
'function)` answers at the REPL, and there is no undocumented private API
that a caller could come to depend on by accident.

## What counts as a security defect

A logging library sits directly downstream of untrusted input — request
paths, user names, error messages. The following are therefore treated as
security defects rather than cosmetic bugs:

- **Log injection or forgery.** Any field value, key, or message that can
  terminate a record early, start a second one, or visually disguise its own
  content in `text-handler` output (control characters, U+2028/U+2029,
  bidirectional or invisible formatting controls), or break out of a string
  in `json-handler` output. See [Handlers](handlers.md).
- **Unbounded resource consumption from a field value.** Any input that makes
  the snapshot walk exceed its documented depth, node, string-length, or
  collection-size bounds, or that makes it fail to terminate. Cyclic and
  hostile structures must signal, not hang or exhaust memory. See
  [Fields](fields.md).
- **Unintended code execution while rendering.** In particular, a path that
  invokes a user-defined `print-object` or condition `report` method that the
  documented API says will not be invoked. See
  [Logging Conditions](conditions.md).
- **Concurrency defects with security consequences**, such as interleaved or
  truncated records from handlers sharing a stream.
- **Unsafe filesystem behavior in `rotating-file-handler`**, including
  deleting a file outside its own rotation set.

Out of scope: the contents a caller deliberately chooses to log. The library
escapes and bounds what it is given; it cannot know that a field value was a
credential.

Report a suspected vulnerability privately through
[GitHub security advisories](https://github.com/nerima-lisp/cl-log-kit/security/advisories/new),
never in a public issue. The org-wide policy is in
[SECURITY](https://github.com/nerima-lisp/.github/blob/main/SECURITY.md).
