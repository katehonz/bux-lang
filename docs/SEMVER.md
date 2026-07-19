# Bux Semantic Versioning Policy

> Status: Draft for v0.x → v1.0 freeze (E.3)

Bux follows [Semantic Versioning 2.0.0](https://semver.org/) with the
clarifications below.

---

## Version numbers

```
MAJOR.MINOR.PATCH[-prerelease]
```

| Component | When it increases |
|-----------|-------------------|
| **MAJOR** | Breaking language / stdlib / CLI changes |
| **MINOR** | Backward-compatible features |
| **PATCH** | Backward-compatible bug fixes |

During **0.x** (pre-1.0):

- `0.MINOR.PATCH` — MINOR may still introduce breaking changes (documented in
  the release notes and `MIGRATION_*.sh` when needed).
- Prefer deprecation warnings for at least one MINOR before removal when
  practical.

After **1.0.0** (language freeze):

- Breaking changes require a MAJOR bump and a migration guide.
- The Language Reference is the normative spec; compiler bugs that contradict
  the ref are fixed without a MAJOR bump.

---

## What counts as “breaking”

- Removing or renaming a public stdlib symbol
- Changing the type or semantics of a public API
- Changing CLI flags that scripts rely on (`build`, `test`, `fmt --check`, …)
- Changing `bux.toml` / `bux.lock` fields in an incompatible way
- Changing the fat `func` / tuple C ABI in a way that breaks linked code

**Not breaking:**

- New keywords that were previously valid identifiers only if reserved carefully
  (prefer contextual keywords)
- New diagnostics / stricter `@[Checked]` (document; may be gated)
- Formatter whitespace-only changes

---

## Package versions (registry)

Registry packages use the same MAJOR.MINOR.PATCH scheme.

`bux add foo` / `bux add foo 0.1` resolution:

| Request | Matches |
|---------|---------|
| `*` / omitted | Latest entry for `foo` in the index |
| `0.1.1` | Exact version |
| `0.1` | First version with that prefix (e.g. `0.1.1`) |

Lockfiles pin the **resolved** version and source path/URL.

---

## Release checklist (maintainers)

1. Update `docs/LanguageRef.md` if behaviour changed
2. Update `docs/QUALITY_PLAN.md` / changelog notes
3. Run `make test` (includes `fmt-check`, examples, goldens)
4. Run `make selfhost-loop`
5. Tag `vMAJOR.MINOR.PATCH`
