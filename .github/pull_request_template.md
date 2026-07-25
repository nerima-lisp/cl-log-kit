## Summary

Describe the change in terms of user-visible behavior or contract impact.

## Validation

List the narrowest commands that demonstrate the change, and say plainly if
something could not be run.

```
# e.g. nix flake check --print-build-logs
#      nix develop -c sbcl --script run-coverage.lisp
```

## Public Surface Impact

Does this change the shape or behavior of any exported symbol? If so, note
the required version bump and the migration path. If not, say so.

## Checklist

- [ ] Specs added or updated for the behavior change
- [ ] `CHANGELOG.md` updated
- [ ] `docs/src/` updated, if documented behavior moved
- [ ] Any new exported symbol has a docstring
- [ ] Coverage floors in `run-coverage.lisp` unchanged — or the change is
      explained above

## Follow-up Risk

Call out any remaining risk, unsupported edge case, or intentional follow-up.
