---
name: Feature request
about: Propose a scoped improvement for cl-log-kit
title: "[feature] "
labels: ["enhancement"]
---

## Problem

Describe the workflow limitation or missing capability.

## Proposed Change

Describe the smallest change that would solve the problem.

## Scope Check

Two project constraints that shape what fits:

- The shipped `cl-log-kit` system has **zero runtime dependencies** (ASDF
  and SBCL only). Does this proposal need one?
- A new destination or encoding is usually a **handler**, not a change to
  the core — see
  [Extending cl-log-kit](https://nerima-lisp.github.io/cl-log-kit/extension/).
  Could this live as a handler outside the library?

## Public Surface Notes

Would this add or change an exported symbol? Anything that changes the shape
or behavior of an existing one needs a major version and a migration path.

## Validation Plan

How should the change be tested or demonstrated?
