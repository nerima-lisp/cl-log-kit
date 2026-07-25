# Security Policy

## Supported Versions

Security fixes are applied to the current mainline release. Earlier releases
are not supported; upgrade to the latest release before reporting a behavior
that may already be fixed.

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability. Report it through
[GitHub private security advisories](https://github.com/nerima-lisp/cl-log-kit/security/advisories/new).

Include a minimal reproduction, the affected version or commit, the impact,
and any suggested mitigation. Avoid publishing exploit details until a
maintainer has coordinated disclosure with affected users.

## Response and Disclosure

Maintainers aim to acknowledge a report within seven calendar days, validate
the issue, and coordinate a fix or mitigation with the reporter. Do not
publish vulnerability details before a coordinated disclosure date is agreed.

## Scope

A logging library sits directly downstream of untrusted input — request
paths, user names, error messages — so the following are in scope and are
treated as security defects rather than cosmetic bugs:

- **Log injection or forgery.** Any field value, key, or message that can
  terminate a record early, start a second one, or visually disguise its own
  content in `text-handler` output (control characters, U+2028/U+2029,
  bidirectional or invisible formatting controls) or break out of a string
  in `json-handler` output.
- **Unbounded resource consumption from a field value.** Any input that
  makes the snapshot walk exceed its documented depth, node, string-length,
  or collection-size bounds, or that makes it fail to terminate. Cyclic
  and hostile structures must signal, not hang or exhaust memory.
- **Unintended code execution while rendering.** In particular, a path that
  invokes a user-defined `print-object` or condition `report` method that
  the documented API says will not be invoked.
- **Concurrency defects with security consequences**, such as interleaved
  or truncated records from handlers sharing a stream.
- Unsafe filesystem behavior in `rotating-file-handler`, including deleting
  a file outside its own rotation set.

Out of scope: the contents a caller deliberately chooses to log. The library
escapes and bounds what it is given; it cannot know that a field value was a
credential.
