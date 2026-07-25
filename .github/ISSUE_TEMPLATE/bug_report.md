---
name: Bug report
about: Report a reproducible defect in cl-log-kit
title: "[bug] "
labels: ["bug"]
---

## Summary

Describe the failure in one or two sentences.

## Reproduction

The smallest form that reproduces it — ideally a self-contained snippet
against a `text-handler` or `json-handler` on a string stream, so the output
is directly comparable.

```lisp
(let* ((out (make-string-output-stream))
       (logger (make-logger :handler (make-instance 'text-handler :stream out)
                            :clock (lambda () 0))))
  ;; ...
  (get-output-stream-string out))
```

## Expected Behavior

## Actual Behavior

Include the emitted line, the condition text, or the backtrace.

## Environment

- SBCL version:
- Platform:
- `cl-log-kit` version or commit:

## Concurrency

If threads are involved: how many, and does it reproduce on every run or
only intermittently? That distinction usually determines where to look
first.
