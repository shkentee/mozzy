# Contributing to wearable-recorder

Thanks for your interest in this project. This guide covers the workflow, conventions, and quality bars expected when contributing.

The authoritative spec lives at [`docs/wearable-recorder-spec.md`](docs/wearable-recorder-spec.md). When in doubt, defer to the spec.

---

## Getting started

You will need:

| Tool | Version | Notes |
|---|---|---|
| nRF Connect SDK | v2.7-branch (container) | Firmware build / Twister / bsim |
| Zephyr | bundled with NCS v2.7 | Pulled via `west.yml` |
| Flutter | 3.24+ | Mobile app (`app_mobile/`) |
| Python | 3.11+ | Tooling (`tools/`) and bsim glue |
| west | latest | NCS workspace tool |
| gh CLI | latest | PR / Issue ops |

Recommended container: the official Nordic NCS dev container pinned to `v2.7-branch`. Local installs work but the CI is the source of truth.

Initial workspace setup:

```bash
git clone https://github.com/shkentee/wearable-recorder.git
cd wearable-recorder
west init -l .
west update
```

Mobile:

```bash
cd app_mobile
flutter pub get
flutter test
```

Tools:

```bash
cd tools
python -m pip install -r requirements.txt   # if present
pytest
```

---

## Development cycle

**Current state (solo / fast iteration):** small, well-scoped commits pushed directly to `main`. CI must stay green on `main` at all times.

**Future state (multi-contributor):** topic branches + PRs.

```
feature/<short-slug>     new functionality
fix/<short-slug>         bug fix
ci/<short-slug>          CI-only change
docs/<short-slug>        docs-only change
```

Open a PR against `main`, fill in the PR template, wait for green CI, request review, then squash-merge.

Whichever mode you are in: **never push a commit that breaks CI on `main`.** If you do, revert first, fix forward second.

---

## Commit conventions

Commit subjects follow these prefixes (derived from the existing history):

| Prefix | Use for |
|---|---|
| `Phase N: ...` | First-time delivery of a Phase milestone (see Phase structure below) |
| `Phase N+: ...` | Extension / hardening of a previously delivered Phase |
| `fix(area): ...` | Bug fix in a specific area (e.g. `fix(bsim): ...`) |
| `ci(area): ...` | CI / workflow / runner change |
| `docs(area): ...` | Documentation only |
| `test(area): ...` | New or updated tests, no behavior change |
| `build(area): ...` | Build system, dependencies, west manifest, Kconfig defaults |

Common `area` values: `firmware`, `mobile`, `tools`, `bsim`, `ble`, `codec`, `storage`, `spec`.

Subject line: imperative, <= 72 chars, no trailing period. Body (optional): wrap at 100 chars, explain the *why*.

---

## Phase structure

Progress is tracked as Phases. See spec `§0.1` (roadmap) and `§22` (status) for current state.

| Phase | Scope |
|---|---|
| Phase 1 | Repository scaffolding, west manifest, board overlays, third-party submodules |
| Phase 2 | CI: firmware build, mobile, tools, bsim smoke + nightly |
| Phase 3 | Twister coverage and bsim BLE protocol harness |
| Phase 4 | Implementation MVP: capture pipeline, codec glue, BLE GATT, storage |
| Phase 5 | On-device flashing, power measurement, real-hardware bring-up (owner: Kenta) |
| Phase 6 | Mobile app + productization |

When you ship a chunk that lands a Phase milestone, use the `Phase N:` prefix and reference the spec section in the PR body.

---

## Testing

Each layer has its own test framework. Run the layer you touched; CI runs everything.

| Layer | Framework | Where | Run locally |
|---|---|---|---|
| Firmware unit | Zephyr ZTEST (Twister) | `tests/` | `west twister -T tests/ -p native_sim` |
| BLE protocol | Babblesim (bsim) | `tests/bsim/` | see `tests/bsim/README` |
| Mobile | `flutter_test` | `app_mobile/test/` | `flutter test` |
| Tools | pytest | `tools/tests/` | `pytest` from `tools/` |

ZTEST naming: every test function **must** be prefixed `test_` (Twister discovery depends on it).

Add a regression test for every bug fix. Add a happy-path test for every new feature.

---

## CI workflows

Five workflows guard `main`:

| Workflow file | Display name | Triggers on | Purpose |
|---|---|---|---|
| `.github/workflows/build.yml` | `firmware-build` | firmware / overlay / boards / west.yml | NCS build matrix for target boards |
| `.github/workflows/bsim.yml` | `bsim-smoke` | firmware / bsim test changes | Fast BLE protocol smoke test on every push |
| `.github/workflows/bsim-nightly.yml` | `bsim-nightly` | schedule | Long-running BLE soak / fuzz |
| `.github/workflows/mobile.yml` | `mobile` | `app_mobile/` changes | `flutter analyze` + `flutter test` + build |
| `.github/workflows/tools.yml` | `tools` | `tools/` changes | `pytest` + lint |

A PR is mergeable when all workflows that ran are green. Docs-only PRs typically only trigger nothing or `tools` — that is expected.

---

## Code quality

- **Comments**: English, short, *why* not *what*. Skip the comment if the code is self-explanatory.
- **Never** put `*/` inside a C/C++ comment body — it has bitten us before. Use `* /` or rephrase.
- **Separate pure logic from Zephyr glue.** Algorithms (codec framing, ring-buffer math, packetization) live in pure C with no Zephyr includes so they are unit-testable on the host. Zephyr-specific code (threads, k_sem, GATT callbacks) is a thin adapter on top.
- **ZTEST function names must start with `test_`.** Twister will silently skip anything else.
- **No dead code.** If you `#if 0` something, add a TODO with an owner and a date or delete it.
- **Mobile (Dart):** run `flutter analyze` clean before pushing. Prefer `const` constructors. No `print` in committed code — use `debugPrint` or a logger.
- **Tools (Python):** type-hint public functions. Keep CLI entrypoints in `if __name__ == "__main__":` blocks so they import cleanly under pytest.
- **No secrets in repo.** Ever. If a key leaks in, rotate it and force-fix the history in a follow-up.

---

## Questions

Open a `task` or `feature` issue using the templates in `.github/ISSUE_TEMPLATE/`. For bugs, use `bug.yml` and include firmware SHA + which workflow failed.
