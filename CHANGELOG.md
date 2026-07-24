# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-07-24

### Fixed

- `close-handler` on a `multi-handler` containing a `null-handler` (or any
  handler that inherits the base `handler-open-p` and so is always open by
  design) no longer spuriously signals `handler-lifecycle-error`. The
  composite close pass had a post-check — `(some #'handler-open-p children)`
  — that treated "a child still reports open" as "that child's close failed",
  but a `null-handler` has no close protocol and is legitimately always open,
  so closing a `multi-handler` that held one always errored even though every
  child closed cleanly. A signaled error is the only reliable close-failure
  indicator and the per-child `handler-case` already captures those, so the
  post-check produced only this false positive and was removed. Found by an
  adversarial source audit and reproduced end to end (a `null-handler` in a
  `multi-handler` errored on close; the same `null-handler` in a
  `filter-handler`, and a `text-handler` in a `multi-handler`, both closed
  cleanly), then pinned with a regression test proven to fail on the old code
  and pass on the new.

### Internal

- Collapsed the seven identical `(%check-snapshot-size :string-length (length x)
  +max-log-field-string-length+)` bound checks scattered across `record.lisp`,
  `logger.lisp`, and `snapshot.lisp` into one intention-named
  `%check-field-string-length` helper, so those call sites state *what* they
  guard rather than repeating the resource keyword and constant (data/logic
  separation; coverage-neutral since the helper is exercised on every path).
- Made `%map-multi-handler` (the fan-out that both `defhandle`/`defflush` and
  `defclose` drive) materially easier to follow by lifting its two failure
  modes into named local functions — `handle-immediate-failure` (handle/flush:
  run the error policy now, so `:signal` aborts the pass) and
  `handle-deferred-failure` (close: remember the first error, run the policy
  callback for side effects, keep going) — plus a shared `apply-error-policy`.
  The `dolist` body is now a two-line branch on `complete-before-signaling`
  instead of a nested `if`/`progn`/`handler-case` pile; behaviour is unchanged
  (`handlers.lisp` branch coverage stays 100%).
- Extended the matcher vocabulary with `:to-have-recorded` (a
  `counting-handler`'s exact record count) and `:to-contain-substring` (a
  rendered line contains a literal substring), then converted the suite's
  remaining plumbing to them: the `(expect (= (length (counting-handler-records
  h)) n) :to-be-truthy)` / `(expect (counting-handler-records h) :to-be nil)`
  record counts, the last `assoc`-based field assertions in
  `property-test.lisp`, and all 31 `(expect (search "…" output) :to-be-truthy)`
  wire-format assertions across `handler`, `coverage`, and `logger` specs
  (`(expect output :to-contain-substring "…")`). The suite's assertions now
  read almost entirely in log-kit vocabulary rather than alist/length/search
  plumbing, and each converted matcher was checked to still reject a wrong
  value so none became vacuously green.
- Wrapped `snapshot.lisp`'s `%call-with-active-snapshot-object` CPS helper in a
  `with-snapshot-object` macro — the same helper-plus-`with-` idiom the project
  already uses for `%call-with-bounded-output`/`with-bounded-output` — and
  routed all five self-referential-value branches of `%snapshot-field-value`
  (`json-object`, `json-array`, `cons`, `array`, `hash-table`) through it,
  dropping the repeated `(... context value (lambda () ...))` boilerplate so
  each branch reads as "check the size bound, then snapshot the children."
  Behaviour and the cycle-detection guarantee are unchanged (129→130 specs
  pass). A parallel attempt to collapse the two value/reason `define-condition`
  forms in `conditions.lisp` into a generating macro was made and then reverted:
  it regressed that file 95.7%→79.4% because `sb-cover` cannot credit a macro
  body, confirming (and now documenting inline) the project rule that macros are
  for behavioral codegen, not load-time definition forms.
- De-duplicated `handler-json.lisp`'s two byte-for-byte-identical
  object-writing loops (`%write-json-object` and the former
  `%write-json-fields`, which differed only in whether the alist came from
  `%json-object-members` or the record's `fields`) into one shared
  `%write-json-members` writer, using `paredit`'s `rename-function` and
  `edit replace` (preview-then-`--write`, `inspect check` before and after)
  so the delimiters were never hand-balanced. `%write-json-object` is now a
  one-line delegation; the JSON hot path allocates identically (the
  performance specs' bounded-allocation assertions still pass).
- Adopted a third nerima-lisp package, `cl-json-kit` (v0.2.0), as a
  **test-only** dependency of `cl-log-kit/test` — it never enters the shipped
  `cl-log-kit` system, which stays dependency-free. The `json-handler` specs
  now parse an emitted line back with an independent JSON reader
  (`json-kit:parse ... :object-type :alist`) and assert on the decoded
  structure ("json-handler output parses back to the expected structure"),
  which catches a malformed object — a stray comma, an unquoted key — that a
  substring `search` cannot. Wired it into `flake.nix`'s `CL_SOURCE_REGISTRY`
  alongside `cl-weave`/`cl-process-kit`, and while re-locking, pinned every
  transitive `paredit-cli` dev-lint input (which the nerima-lisp package flakes
  still reference at the pre-org-move `github:takeokunn/paredit-cli` URL) to
  `github:nerima-lisp/paredit-cli` via `follows`, so `flake.lock` now carries
  zero `takeokunn` references and the previously incomplete lock (it had never
  pinned `cl-process-kit`) is consistent again.
- Added a `cl-weave` `it-fuzz` test (`gen-one-of`/`gen-character`, 200 trials,
  a bounded `:timeout-per-trial 2`) asserting the text handler's *totality*
  contract: it renders any generated field value — integers, booleans,
  strings, keywords, and arbitrary characters including control and
  line-breaking ones — as exactly one safe physical line, never signaling, so
  a hostile value cannot crash logging. This exercises the crash-proof design
  (bounded number/character/symbol renderings, `#<object>` placeholder for
  everything else) across many inputs instead of the single hand-picked
  hostile-printer case.
- Adopted `cl-weave`'s advanced property generators (`gen-recursive` +
  `gen-one-of`) to fuzz the recursive defensive snapshot — the library's most
  complex, security-relevant code — with nested field values of arbitrary
  depth and shape, instead of the hand-picked examples the other specs use.
  The new invariant ("recursively snapshots arbitrary nested field values")
  asserts the snapshot is both a faithful structural copy (`equal`) and shares
  no mutable cons cell or non-empty string with the source (a new
  `shares-no-structure-p` support helper, itself checked to reject same-object
  and partial-sharing inputs). Confirms end to end that deep snapshotting can
  never leak a caller-mutable substructure into an immutable record (131 specs).
- Raised the test suite's assertion abstraction by extending `cl-weave`
  itself with a log-kit matcher vocabulary (`t/matchers.lisp`, registered
  through `cl-weave:expect-extend`): `:to-have-field`, `:to-have-field-matching`,
  `:to-lack-field`, and `:to-be-single-line`. This collapsed ~40 hand-rolled
  `(expect (string= (cdr (assoc :k fields)) "v") :to-be-truthy)` /
  `(expect (null (assoc :k fields)) :to-be-truthy)` /
  `(expect (= 1 (count #\Newline output)) :to-be-truthy)` plumbing chains
  across `logger`, `record`, `span`, `composition`, `coverage`, `handler`,
  and `property` specs into intention-revealing assertions
  (`(expect fields :to-have-field :k "v")`). The field matchers look keys up
  by log-kit's own canonical rule (case-insensitive, symbol-or-string), so a
  spec names the field it means rather than the exact key object stored, while
  value comparison stays strict (`equal`, not `equalp`) to preserve the
  original `string=`/`=` strictness — verified by an adversarial negative pass
  confirming each matcher rejects a wrong value, a missing key, a
  case-mismatched value, a false predicate, and a multi-line string, so no
  converted assertion became vacuously green. The full suite (129 examples)
  and the `sb-cover` coverage gate both pass unchanged.
- Adopted a second nerima-lisp package,
  [`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit), as a
  dev-tooling-only dependency (not part of the `cl-log-kit` or
  `cl-log-kit/test` `:depends-on`, so the shipped library stays
  dependency-free) and added `run-ci.lisp`, an entry point that runs
  `run-tests.lisp` or `run-coverage.lisp` as a child SBCL process via
  `process-kit:run`. This turns "command execution timeout" from a
  README-documented `timeout 120s` shell convention a caller has to
  remember into an enforced default: `cl-process-kit` polls the child,
  escalates SIGTERM to SIGKILL after a grace period on timeout, and
  `run-ci.lisp` maps that to exit code `124` (matching `timeout(1)`).
  Verified end to end, not just read: a deliberately hung child (`(sleep
  30)`) was killed at the configured 2-second timeout in 2.1s wall-clock,
  and a real `run-ci.lisp tests 1` invocation against the full suite
  correctly timed out and exited 124. `flake.nix` gained a `cl-process-kit`
  input and the `apps.test`/`checks.default` derivations now run through
  `run-ci.lisp tests`.
- Migrated `run-coverage.lisp` from hand-driving `sb-cover:report` to
  `cl-weave:run-all`'s native `:coverage`/`:coverage-minimum-expression`/
  `:coverage-minimum-branch` support (same underlying `sb-cover` data,
  confirmed by re-deriving the identical 95.44%/98.21% aggregate through
  both paths) so a coverage regression is now a hard build failure instead
  of a report nobody reads. The floors (95.0% expression / 98.0% branch)
  sit just under the actual achieved aggregate as a safety margin; a real
  regression fails loudly (`error`), verified by temporarily setting the
  expression floor to 99.0% and confirming `run-coverage.lisp` reported
  "95.44% is below 99.00%" and exited non-zero, then reverting. This also
  surfaced and fixed a real bug in the migration: `run-all`'s
  `:coverage-reset` defaults to `T`, which wiped the load-time coverage
  credit the original script's proclaim-around-`(asdf:load-system
  :force t)` dance intentionally preserves — measured 92.36% instead of
  95.44% until `:coverage-reset nil` was passed explicitly. `100%` remains
  out of reach for the reason documented throughout this file (declarative
  forms, constant-folded defaults, and code unreachable by construction
  cannot be "tested into" coverage) — this gate makes that ceiling an
  enforced fact about the build rather than a claim in a comment.
- `cl-dataflow` and `cl-json-kit` were re-evaluated alongside this session's
  `cl-process-kit` adoption and still rejected for the reasons already
  recorded here: `cl-dataflow` pulls in a full Prolog engine and its
  pipeline/node model has no place for a broadcast-sink handler with an
  open/flush/close lifecycle; `cl-json-kit` is a plausible value-model
  match but would make JSON handling a `src/` dependency, contradicting
  the "dependency-free" description this project states about itself in
  both `cl-log-kit.asd` and `README.md`.
- Split the source into single-responsibility files loaded in dependency
  order: `conditions`, `snapshot`, and `record` (from the old `record`);
  `handler`, `handler-text`, and `handler-json` (from the old `handler`);
  `lifecycle` and `handlers` (from the old `composition`); and
  `convenience`, `condition-logging`, and `span` (from the old
  `convenience`). No file now exceeds ~250 lines.
- Generated the ten `log-<level>` / `log-default-<level>` macros from a
  single data table via `define-log-level-macros`, replacing ten
  hand-written definitions with one macro-generating macro.
- Extracted the bounded condition-report machinery into a
  `%call-with-bounded-output` / `with-bounded-output` continuation
  (CPS) helper, removing the duplicated stream-setup-and-teardown code.
- Collapsed the nine composite-handler methods onto a `defhandle` /
  `defflush` / `defclose` macro DSL that passes each method body as the
  continuation to the lifecycle guards, so the open/close boilerplate is
  written exactly once.
- Reorganized the test suite around local `describe` groups, shared
  fixtures in `t/support.lisp`, `it-each` tables, and `it-property`
  invariants (level ordering, single-line text output, snapshot isolation,
  and plist/JSON de-duplication).
- Added `run-coverage.lisp`: `sb-cover`-instrumented coverage over `src/`
  with a source-filtered HTML report under `coverage/`. Coverage varies with
  the suite and toolchain; residual uncovered forms are
  load-time definition forms (`defpackage` exports, class/struct/condition
  slots) that `sb-cover` cannot credit, plus branches that are unreachable
  by construction (`etypecase` exhaustiveness, always-proper `&rest`
  initargs, and a deep three-thread close race).
- Replaced the ad hoc local test-framework clone with a real dependency on
  [`nerima-lisp/cl-weave`](https://github.com/nerima-lisp/cl-weave): added it
  to `cl-log-kit/test`'s `:depends-on`, wired it into `flake.nix` as a flake
  input on the `CL_SOURCE_REGISTRY`, and adopted its mock functions
  (`make-mock-function`), inline snapshots (`:to-match-inline-snapshot`), and
  mutation testing (`run-mutations` / `assert-mutation-score`) where they fit
  naturally alongside the existing `describe` / `it` / `expect` / `it-each` /
  `it-property` specs.
- Extracted `WITH-LOG-SPAN`'s ninety-line macro body into a
  `%call-with-log-span` continuation, matching the `%call-with-bounded-output`
  and `%call-with-open-handler-operation` CPS helpers: the macro now only
  decides whether a span is worth starting, and the span lifecycle itself is
  a plain, testable function.
- De-duplicated the repeated field-pair-copy and duplicate-canonical-key
  checks in `snapshot.lisp` into `%copy-field-pair` /
  `%check-duplicate-canonical-key`, and the repeated boolean-initarg checks
  in `handler.lisp` into `%check-boolean-initarg`.
- Restored idiomatic reader-macro shorthand (`'symbol`, `#'function`) and
  hand-quality indentation across `src/*.lisp`, which had regressed to
  `(quote symbol)` / `(function f)` and cramped one-argument-per-line
  formatting from an earlier mechanical pass.
- Removed `(declaim (inline level< level<=))`: on SBCL, inlining a declared
  function substitutes its source at every call site, so the compiled,
  coverage-instrumented standalone function body was never the code path
  actually taken and `sb-cover` reported it "not executed" even under test.
  These are one-line wrappers around `<`/`<=`; the inlining was not worth
  hiding real coverage behind.
- Pinned `cl-log-kit.asd` to a minimum ASDF `3.3.1` and the test system to a
  minimum `cl-weave` `0.8.0`, so a stale ASDF or cl-weave fails fast with a
  version error instead of a confusing missing-symbol error mid-load.
- Replaced the ad hoc `signals-condition-p` / `signals-unsupported-json-p`
  boolean helpers (`handler-case` + `(expect ... :to-be-truthy)`) with
  `cl-weave`'s native `signals` macro and `:to-throw` matcher at all ~36 call
  sites across the suite, and extracted `t/support.lisp`'s
  `render-json-value` for the one case that still composes two steps.
- Used `paredit refactor extract-local-function` (plan → preview → write →
  verify) to pull the repeated "wait until the stream is closed" loop out of
  `close-handler` into `%wait-until-stream-closed`. Its first `--infer-params`
  attempt misread `loop`'s `until`/`do` keywords as free variables and
  produced a broken 3-argument signature; the preview step (no `--write`)
  caught this before anything was written, and `--param state` (explicit,
  not inferred) produced the correct one-argument extraction.
- Closed every coverage gap traceable to a missing test case, found by
  reading `coverage/<hash>.html` line-by-line rather than trusting the
  summary percentage: `%proper-list-p`'s circular- and dotted-list branches
  (`multi-handler` with a circular or oddly-shaped dotted handler list),
  `%write-json-value`'s final `unsupported-json-value` fallback (called
  directly with a raw cons/hash-table/ratio, bypassing the validation pass
  that normally intercepts those first), and `%json-key-string`'s string
  clause (a JSON record with a raw string field key). Expression/branch
  coverage moved 93.1%/95.7% → 94.3%/97.5% across this and the prior round.
  The remaining gap is almost entirely non-executable by construction:
  `defpackage`/`defclass`/`defstruct` declarative forms, `defconstant`/
  `defvar`/`defparameter` bindings, `defgeneric` forms with only a
  `:documentation` option, and — newly identified this round — `defmacro`
  body forms themselves (they run at macroexpansion/compile time, which
  `sb-cover`'s runtime `store-coverage-data` instrumentation cannot observe,
  even though the macro visibly expanded and its expansion executes).
- Closed the `handler.lisp` three-thread close race previously documented as
  too-precise to reach deliberately: it needed two *owning* handlers on one
  shared stream, not an owner and a peer — a non-owning handler's
  `close-handler` takes an unconditional early-return clause and never
  reaches the closing-p wait branches at all. With two owning handlers and a
  `finish-callback-stream` to pin the exact moment of physical finalization,
  the race reproduces deterministically every run (`handler.lisp`
  88.3%/91.7% → 91.8%/95.8%). Expression/branch coverage overall:
  93.1%/95.7% → 94.9%/98.2% across four rounds.
- Removed the `handler-case (arithmetic-error () ...)` wrapping
  `sb-ext:float-infinity-p`/`float-nan-p` in `handler-text.lisp`: their
  disassembly (`sbcl --eval '(disassemble #'sb-ext:float-nan-p)'`) shows pure
  integer bit-decoding of the float's exponent/mantissa fields — no
  floating-point instruction, no trap, ever. Unlike `handler-json.lisp`'s
  `%finite-float-p`, which performs *real* arithmetic (`-`, `=`) on the
  value and can genuinely trap on a signaling NaN under default float traps
  (and is already exercised), this handler-case could never catch anything;
  it was dead code, not merely hard-to-test. Removing it took
  `handler-text.lisp` to 99.5%/100% — only its `in-package` form remains
  uncovered.
- Bumped the `cl-weave` version floor from `0.8.0` to `0.10.0` in
  `cl-log-kit.asd` and re-locked `flake.nix`'s `cl-weave` input to the
  tagged `v0.10.0` commit (`7ddc1a28`), which includes a "runtime
  correctness in hooks, isolation, watch, and CLI" fix landed the same day
  and absent from the previously locked pre-release commit. The full suite
  (125 examples) passes unchanged against the updated framework.
- Identified, but did not chase, one more sb-cover artifact while
  auditing `record.lisp` (82.0%) and `handlers.lisp` (89.2%), the two
  lowest-covered files with real logic: every `&key`/`&optional`
  default-value form built from a self-evaluating constant (e.g.
  `(level +level-info+)`, `(auto-flush t)`) is reported "Not executed"
  even when a call that omits the keyword genuinely exists and passes
  (`(make-log-record)` with zero arguments, exercised in
  `composition-test.lisp` and `coverage-test.lisp`). SBCL's compiler
  constant-folds these defaults at the call site the same way it inlines
  a `declaim`d function, so the coverage probe tied to that source
  position never fires even though the code path runs. Same root cause
  as the `level<`/`level<=` inlining case above; not a real test gap.
  The same pattern recurs in `handler.lisp`, `logger.lisp`, and
  `condition-logging.lisp`'s constructors — confirmed by inspecting each
  file's per-span HTML report rather than assuming from the summary
  percentage, since the crude heuristic of "any red span on this source
  line" over-flags lines that are mostly covered with one folded
  sub-form (e.g. `record.lisp:32`'s `defun` header is 80% green with
  only the four default-value literals red).
- Closed four real coverage gaps found by that same per-span audit,
  each confirmed by comparing the exact HTML span (not just the
  line) against the test suite before writing a test:
  - `handlers.lisp`'s `defflush multi-handler` and `defflush
    filter-handler` bodies were never reached in an *open* state — every
    existing `flush-handler` call on a multi/filter-handler in the suite
    ran only after `close-handler`, exercising the "rejected, already
    closed" guard instead. Added "flushes every child of an open
    multi-handler and an open filter-handler's target" to
    `composition-test.lisp`.
  - `%map-multi-handler`'s innermost `(error (callback-error)
    (remember-error callback-error))` — the branch where a `:callback`
    error-policy's own callback itself signals while handling a close
    failure — had no test where the callback raised. Added "remembers
    an error-callback's own failure as the close error".
  - `%call-with-log-span`'s cleanup `(error cleanup-condition)` re-signal
    only fires when the span body *succeeded* and the `:end` record
    emission then fails; both existing `span-test.lisp` cleanup-failure
    tests had the body throw first, so `primary-condition` was always
    set and the re-signal never ran. Added "signals the end-record
    failure when the body already succeeded".
  - `%bounded-character-output-stream`'s `stream-write-string` computes
    `(length string)` only when a caller omits `:end` — the standard
    default for `(write-string string stream)` — but `with-bounded-output`
    had no direct test, only indirect exercise through `condition-fields`'
    `princ` calls, which never happened to omit `:end` at the Gray-stream
    dispatch layer. Added "bounded output streams default a
    caller-omitted write-string end to the string length", calling
    `log-kit::with-bounded-output` directly. Together these four tests
    moved `handlers.lisp` 89.2%/100% → 93.9%/100%, `span.lisp`
    96.4%/-- → 98.2%/--, and `condition-logging.lisp` 94.2%/100% →
    95.1%/100%.
  - Confirmed one adjacent case is genuinely unreachable rather than
    undertested: `%validate-logger-initargs`'s `(unless (%proper-list-p
    initargs) (error 'program-error))` guard (`logger.lisp:29`) can
    never fire through any legal call to `initialize-instance`, because
    a generic function's `&rest` parameter is always bound to a freshly
    consed, finite, proper list built from the actual call arguments —
    there is no calling convention that hands it an improper or
    circular one. Left uncovered and undocumented-as-a-gap on purpose,
    the same category as `%snapshot-field-value`'s fresh-context
    fallback (`snapshot.lisp:93`), confirmed unreachable earlier: every
    public entry point already binds `*field-snapshot-context*` before
    any call reaches it, so the `(%make-snapshot-context)` branch of
    its `or` cannot run either.
  - All eleven remaining low-coverage files were re-audited the same
    way (exact span, not line) and every uncovered span falls into an
    already-documented, non-executable-by-construction bucket:
    `in-package` forms, `defclass`/`defstruct` slot lists,
    `defconstant`/`defvar`/`defparameter` bindings, `defgeneric` forms
    with only a `:documentation` option, `defmacro` bodies (compile-time
    only), and the `&key`/`&optional` constant-folding artifact above.
    No further gaps found.
- Hardened the last unbounded thread-synchronization waits in
  `composition-test.lisp`'s close-once lifecycle tests
  (`sb-thread:wait-on-semaphore`/`join-thread` calls with no `:timeout`)
  to match the `:timeout 1` / `:default nil` convention already used
  everywhere else in the suite: a regression that reintroduces a
  deadlock in the close-once or admitted-operation guards now fails
  that one test in about a second instead of hanging the entire CI run
  indefinitely. `handler-test.lisp`'s apparently-unbounded
  `wait-on-semaphore` calls were re-checked and left alone — they are
  the intentional "hold" point inside a background thread's own
  callback, already gated by a bounded wait on the main test thread, not
  an unguarded wait on the suite's critical path.

## [1.0.0]

### Added

- Numeric standard and custom log levels, early level filtering, immutable
  log records, and injectable clocks.
- Recursive defensive snapshots for strings, conses, arrays, hash tables,
  and explicit JSON containers. Cycles and bounded depth, node, string, and
  collection limits produce structured conditions instead of unbounded
  traversal.
- Explicit `json-object` and `json-array` wrappers plus distinct JSON null
  and false sentinels. JSON output validates supported values and escapes
  strings without silently stringifying unsupported objects.
- Immutable logger derivation with `derive-logger`, `logger-child`, and
  `logger-with`, plus dynamically scoped `with-log-context`. Field
  precedence is event fields over dynamic context over logger fields.
- `multi-handler`, `filter-handler`, `function-handler`, and `null-handler`
  composition, including configurable error policies.
- A handler lifecycle protocol with flushing, idempotent closing,
  `handler-open-p`, `with-handler`, stream ownership, shared stream
  serialization, and reentrant-safe owned-stream finalization.
- `condition-fields` and lazy `log-condition` support with bounded condition
  reports and backtraces.
- Structured conditions and readers for invalid fields, unsupported JSON
  values, and resource-limit failures.
- Tests covering the public API, level filtering, exactly-once emission,
  composition and lifecycle behavior, recursive immutability, JSON and text
  escaping, logger context, condition reporting, and performance
  regressions.

### Changed

- Logging entry points are macros that check the level before evaluating
  messages or fields, avoiding record construction, clock access, and
  handler work for filtered events.
- Field validation canonicalizes symbol and string keys
  case-insensitively, rejects duplicates and malformed property lists, and
  uses hash-based merging to avoid repeated linear scans.
- Text output uses an escaped, machine-parseable
  `ts=... level=... logger=... msg=... field.<key>=...` format. Untrusted
  values cannot inject or disguise additional log lines.
- Stream writes and automatic flushes execute as one serialized operation,
  preventing output from handlers sharing a stream from interleaving.

### Breaking Changes

- `log-debug`, `log-info`, `log-warn`, `log-error`, and `log-fatal` now
  require an explicit logger as their first argument. Default-logger calls
  use the corresponding `log-default-*` macros.
- Logging calls and `make-log-record` accept fields as property lists rather
  than the earlier ad-hoc field representation.
- Text-handler output is not wire-compatible with the earlier
  `[LEVEL] message key=value` format.
- Nested JSON objects and arrays must use the explicit wrappers; arbitrary
  lists and vectors are no longer inferred or silently coerced.
