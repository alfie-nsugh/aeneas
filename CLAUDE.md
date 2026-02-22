# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Aeneas is a verification toolchain that translates Rust programs (via Charon's LLBC intermediate representation) to pure lambda calculus for formal verification. It outputs code for F*, Coq, HOL4, and Lean backends.

The pipeline: **Rust source → Charon (produces `.llbc`) → Aeneas (symbolic interpreter + pure translation) → backend output (F*/Coq/Lean/HOL4)**

## Build Commands

```bash
# Build everything (binary + library + test runner)
make

# Build just the OCaml binary
cd src && dune build

# Format OCaml source
cd src && dune fmt || true

# Run all tests (requires charon setup first)
make test

# Run a single test (e.g., for arrays.rs)
make test-arrays.rs

# Re-run tests, regenerating the .llbc files as needed
REGEN_LLBC=1 make test-arrays.rs

# Verify generated F* files
make verify

# Setup Charon dependency (required before testing)
make setup-charon

# Extract Lean standard library models (after modifying backends/lean)
make extract-lean-std
```

The built binary is at `bin/aeneas`. Usage: `./bin/aeneas -backend {fstar|coq|lean|hol4} [OPTIONS] FILE.llbc`

## Architecture

### Source layout (`src/`)

The translation pipeline is organized into these subdirectories:

- **`llbc/`** — AST definitions and utilities for the LLBC IR produced by Charon. `LlbcAst.ml` is the main AST type; `LlbcOfJson.ml` deserializes from Charon's JSON output; `Contexts.ml` defines the interpreter state (environments with borrows, loans, symbolic values).

- **`interp/`** — The symbolic interpreter. `Interp.ml` is the entry point; it runs the LLBC functions symbolically producing a `SymbolicAst.expr`. The interpreter handles borrow semantics by tracking loans/borrows in `InterpBorrows.ml` and resolves joins/loop fixed points in `InterpJoin.ml` / `InterpLoops.ml`.

- **`symbolic/`** — Converts the `SymbolicAst` from the interpreter to the `Pure` AST. `SymbolicToPure.ml` is the main entry point, delegating to `SymbolicToPureExpressions.ml`, `SymbolicToPureTypes.ml`, etc.

- **`pure/`** — The pure functional AST (`Pure.ml`) and micro-passes that optimize/normalize it before extraction. Key passes live in `PureMicroPasses*.ml`. `PureMicroPassesLoops.ml` handles the loop-to-recursive-function transformation.

- **`extract/`** — Backend-agnostic and backend-specific pretty-printers. `ExtractBase.ml` defines the extraction context; `ExtractTypes.ml` and `Extract.ml` handle types and functions; `ExtractBuiltin.ml` / `ExtractBuiltinLean.ml` define models for Rust standard library items.

- **`utils/`** — Generic collections, identifiers, SCC computation.

- **`aeneas-ppx/`** — A PPX rewriter that transforms `[%craise]`, `[%save_error]`, `[%ltrace]`, etc. into calls that automatically capture `__FILE__` and `__LINE__` for error reporting.

Top-level files: `Main.ml` (CLI argument parsing and top-level orchestration), `Translate.ml` (drives symbolic interpretation then extraction per-function), `PrePasses.ml` (AST passes run before the interpreter), `BorrowCheck.ml` (borrow-check-only mode), `Config.ml` (all global flags), `Errors.ml` (error accumulation), `Logging.ml` (per-module loggers using easy_logging).

### Test infrastructure (`tests/`)

- `tests/src/` — Rust test files. Each file can have `//@` header comments that configure the test run:
  - `//@  skip` — skip this test
  - `//@  known-failure` — expect failure
  - `//@  [lean,coq] aeneas-args=-split-files` — backend-specific aeneas options
  - `//@  charon-args=...` — extra Charon options
  - `//@  subdir=...` — output subdirectory
- `tests/test_runner/` — OCaml test runner (`run_test.ml`) that invokes Charon then Aeneas and optionally compares output against `.out` reference files.
- `tests/{fstar,coq,lean,hol4}/` — Hand-written proof scripts and generated output files checked into the repo.

### Backend libraries (`backends/`)

- `backends/lean/` — Lean 4 library (`Aeneas` package) with primitives, progress tactics, and divergence handling. Run `make extract-lean-std` to regenerate `src/extract/ExtractBuiltinLean.ml` after modifying Lean models.
- `backends/fstar/`, `backends/coq/`, `backends/hol4/` — Standard libraries for each backend.

## Key Conventions

- **OCaml PPX macros**: `[%craise]` (raise error with location), `[%save_error]` (record non-fatal error), `[%ltrace]` / `[%ldebug]` (log with location). These are defined in `aeneas-ppx/AeneasPpx.ml`.
- **Logging**: Each module creates its logger in `Logging.ml`. Use `-log ModuleName` CLI flag to enable trace-level logging for a specific module during debugging.
- **Charon dependency**: `./charon` must be a clone of the Charon repo at the commit specified in `./charon-pin`. Use `make setup-charon` to set it up automatically.
- **Regenerating tests**: After changing Aeneas, run `make test` to regenerate output files. Commit the updated generated files. Generated files are marked with `THIS FILE WAS AUTOMATICALLY GENERATED BY AENEAS`.
- **Builtin models**: When adding Lean standard library models, annotate them with `rust_type`, `rust_fun`, `rust_trait`, etc. attributes, then run `make extract-lean-std` to update `src/extract/ExtractBuiltinLean.ml`.
