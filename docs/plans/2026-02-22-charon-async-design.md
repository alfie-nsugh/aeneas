# Charon Async Support Design

**Date:** 2026-02-22
**Status:** Approved
**Scope:** `async fn` + `.await` (milestone 1); extensible to `gen {}`, `async gen {}`, async closures

---

## Milestone 1 Constraints (stated loudly)

This milestone covers **async without cancellation/drop-while-pending**. Specifically:

- Any coroutine whose MIR contains `TerminatorKind::CoroutineDrop` is rejected with a clear error.
- Any coroutine with `Yield.drop = Some(_)` is rejected with a clear error.
- `CoroutineClosure` (`async` closures) is out of scope; only `async fn` is supported.

These constraints must be prominent in test comments and error messages. Dropping/cancelling a pending future is normal in real-world async Rust; removing these restrictions is the primary goal of milestone 2.

---

## Section 1: Overall Architecture

The design is a two-pass pipeline with clean separation of concerns.

```
Rust source (async fn leaf() -> u32 { 3 })
      │
      ▼  [Pass 1 — faithful translation]
ULLBC with Yield terminators
  - TypeDeclKind::Coroutine { kind, yield_ty, resume_ty, output, upvar_tys }
    registered for each async fn's anonymous coroutine type
  - FunDecl body (the coroutine body, not yet a poll fn) tagged ItemSource::Coroutine
  - Body contains TerminatorKind::Yield { value, resume_arg, resume, drop }
      │
      ▼  [desugar_coroutines — new ULLBC pass]
ULLBC with no async-specific nodes
  - TypeDeclKind::Coroutine replaced by TypeDeclKind::Enum (Running|Start|Suspend_i|Done)
  - Coroutine body FunDecl rewritten into ordinary poll FunDecl
  - All Yield terminators replaced by: store state → return Poll::Pending
  - Resume points become dispatcher branches at the top of the poll function
      │
      ▼  [rest of ULLBC_PASSES → ullbc_to_llbc → LLBC_PASSES]
LLBC with ordinary enums and ordinary functions
```

**Key invariant:** after `desugar_coroutines`, nothing in the pipeline sees async-specific nodes. Aeneas, and the Lean backend, require zero new handling.

**Pass placement:** `desugar_coroutines` is inserted into `ULLBC_PASSES` (in `transform/mod.rs`), after the existing cleanup passes (which ensure `StorageLive`/`StorageDead` are present) and before `ullbc_to_llbc`.

**MIR phase assumption:** Pass 1 requires pre-coroutine-lowering MIR, where `Yield`/`CoroutineDrop` terminators and coroutine aggregates are still present. This is already guaranteed by Charon's `mir_opt_level = Some(0)` in `driver.rs`, which prevents rustc's `StateTransform` pass from running. This setting must not be changed.

---

## Section 2: New AST Nodes

Three files in Charon gain new variants.

### `charon/src/ast/types.rs` — `TypeDeclKind`

```rust
TypeDeclKind::Coroutine {
    /// Async, Gen, or AsyncGen — enables "narrow now, broad later"
    kind: CoroutineKind,
    /// Yield type (for async fn: ())
    yield_ty: Ty,
    /// Resume argument type (for async fn: ())
    resume_ty: Ty,
    /// Return type (the T in async fn -> T)
    output: Ty,
    /// Captured upvars
    upvar_tys: Vec<Ty>,
}

enum CoroutineKind { Async, Gen, AsyncGen }
```

This is an abstract placeholder. The `desugar_coroutines` pass replaces it with a concrete `TypeDeclKind::Enum`.

### `charon/src/ast/ullbc_ast.rs` — `TerminatorKind`

```rust
TerminatorKind::Yield {
    /// Value produced at suspension (for async fn: ())
    value: Operand,
    /// Place that receives the resume argument on re-entry
    resume_arg: Place,
    /// Block to jump to when resumed
    resume: BlockId,
    /// Block to jump to if dropped while suspended (None = no drop glue)
    drop: Option<BlockId>,
}
TerminatorKind::CoroutineDrop,
```

Mirrors rustc MIR exactly. `drop` is `Option` to faithfully represent absence of drop glue.

### `charon/src/ast/gast.rs` — `ItemSource`

```rust
ItemSource::Coroutine {
    /// The TypeDeclId of the coroutine state type registered in Pass 1
    coroutine_ty: TypeDeclRef,
}
```

Links the coroutine body `FunDecl` to its associated `TypeDecl`. Removed by `desugar_coroutines`; the rewritten poll `FunDecl` becomes `ItemSource::TopLevel`.

---

## Section 3: Translation Layer (Pass 1)

Four files change. The pattern follows closures throughout.

**Phase assumption:** Pass 1 translates pre-coroutine-lowering MIR. The `Yield`/`CoroutineDrop` terminators and coroutine aggregates are present because `mir_opt_level = Some(0)`.

### `translate_types.rs`

Line 280 currently raises an error for `TyKind::Coroutine`. New behavior:

```rust
hax::TyKind::Coroutine(item_ref) => {
    let tref = self.translate_coroutine_type_ref(span, item_ref)?;
    TyKind::Adt(tref)
}
// TyKind::CoroutineClosure — remains raise_error! for milestone 1
```

`translate_coroutine_type_ref` (new, mirrors `translate_closure_type_ref`): queues the coroutine's def_id for registration as a `TypeDecl` and as a coroutine body `FunDecl` (which `desugar_coroutines` will later rewrite into a poll function), then returns a `TypeDeclRef`.

### `translate_items.rs` — type decl side

`translate_type_decl` already routes `FullDefKind::Closure`. For `async fn`, the anonymous coroutine type also arrives as `FullDefKind::Closure` (hax's doc: "A closure, coroutine, or coroutine-closure"). A new branch detects the coroutine case:

```rust
FullDefKind::Closure { args, .. } if args.is_coroutine() => {
    self.translate_coroutine_adt(span, args)
}
```

`translate_coroutine_adt` extracts `yield_ty`, `resume_ty`, `output`, `upvar_tys` from `ClosureArgs` and returns `TypeDeclKind::Coroutine { kind: CoroutineKind::Async, .. }`.

### `translate_items.rs` — fun decl side

The coroutine body is also `FullDefKind::Closure`. The same `is_coroutine()` branch tags the resulting `FunDecl`:

```rust
src: ItemSource::Coroutine { coroutine_ty: tref }
```

The body translation proceeds to `translate_bodies.rs` where the four rejection sites are now handled.

### `translate_bodies.rs` — four rejection sites

| Rejection site | Old | New |
|---|---|---|
| `AggregateKind::Coroutine(args)` | `raise_error!` | `Rvalue::Aggregate(AggregateKind::Adt(coroutine_tref, None, None), upvar_args)` — placeholder constructor for "create coroutine with these upvars"; `desugar_coroutines` rewrites this to the concrete `Start` variant constructor |
| `TerminatorKind::Yield { value, resume_arg, target, drop }` | `raise_error!` | `TerminatorKind::Yield { value, resume_arg, resume: target, drop }` — faithful translation |
| `TerminatorKind::CoroutineDrop` | `raise_error!` | `TerminatorKind::CoroutineDrop` — faithful translation |
| `AssertKind::ResumedAfterReturn/Drop/Panic` | `raise_error!` | `Assert { on_failure: Abort(Panic) }` — runtime panic, not UB |

---

## Section 4: `desugar_coroutines` Pass Algorithm

A new `UnstructuredBody` pass in `ULLBC_PASSES`. Runs on every `FunDecl` tagged `ItemSource::Coroutine`. Skips all other items.

### Step 0 — Scope guard

Before any rewriting, reject:
- Any `Yield` with `drop = Some(_)` → `raise_error!("async cancellation not yet supported (milestone 2)")`
- Any `TerminatorKind::CoroutineDrop` anywhere in the body → `raise_error!("coroutine drop glue not yet supported (milestone 2)")`

### Step 1 — Collect and number suspension points

Walk the CFG in postorder from the entry block, breaking ties by increasing `BlockId`. Number each `TerminatorKind::Yield` encountered: `yield_0`, `yield_1`, etc. Deterministic numbering gives stable test output across upstream changes.

### Step 2 — Liveness analysis

Run true backwards dataflow to compute, for each `yield_i`, the set of ULLBC locals live across that suspension point: defined on some path before `yield_i` and used on some path after resumption.

ULLBC locals (post-translation) are the unit of analysis, not rustc locals. A local is considered live if any `Place` referencing it — including via projections — is used. "Any projection use ⇒ base local live" is the conservative rule for milestone 1.

`StorageLive`/`StorageDead` markers may be used as a conservative upper bound fallback if full dataflow is too costly in the initial implementation. This is a temporary simplification: it will store unnecessary locals but is always correct. Label it explicitly in the code.

**Child futures:** locals holding in-progress child futures are naturally live across their associated yields and will appear in the liveness set. This is required — without them the resumed segment has nothing to poll.

### Step 3 — Generate the state enum

Replace `TypeDeclKind::Coroutine { .. }` with `TypeDeclKind::Enum`:

```
FooState::Running                          — ephemeral, set during execution
FooState::Start    { upvar_0: T0, ... }    — initial state (only if there are suspension points)
FooState::Suspend0 { live_a: A, ... }      — includes child future locals
FooState::Suspend1 { live_b: B, ... }
...
FooState::Done                             — unit variant; polling again panics
```

`Running` and `Start` are only generated for coroutines with at least one suspension point (at least one `Yield` terminator). For coroutines with no suspension points, the state enum is simply `Start | Done`.

**Upvars:** upvars are unpacked from `Start` into ordinary locals at function entry. If an upvar is live across a subsequent yield, liveness will include it in the relevant `Suspend_i` variant. No "shared fields" structure is needed.

**Placeholder rewrite:** `AggregateKind::Adt(tref, None, None, upvars)` from Pass 1 is rewritten to `AggregateKind::Adt(tref, Some(VariantId::Start), None, upvars)`.

### Step 4 — Rewrite the coroutine body into a poll function

**New signature:**
```
fn foo_poll(state: &mut FooState, ctx: &mut Context) -> Poll<T>
```

`Poll<T>` is a prelude ADT registered by Charon (see Section 5). `Context` is an opaque prelude ADT. Both must be present in the crate's type environment before `desugar_coroutines` runs; the pass inserts constructors `Poll::Pending` and `Poll::Ready(val)`.

**Entry dispatch block** — `Switch` on `discriminant(*state)`:
- `Running` → `Assert { cond: false, on_failure: Abort(Panic) }` (re-entrant poll)
- `Done` → `Assert { cond: false, on_failure: Abort(Panic) }` (polled after completion)
- `Start` → jump to prologue block `P_start`
- `Suspend_i` → jump to prologue block `P_i`

**Prologue blocks (new generated blocks):**

Each prologue block `P_i`:
1. `tmp = move *state` — move enum value out
2. `*state = Running` — mark in-progress (re-entrant poll → dispatch hits `Running` → panic)
3. Move fields from `tmp.Suspend_i` into local variables
4. `goto original_resume_target`

`P_start` unpacks upvars from `tmp.Start` into locals, then jumps to the original entry block.

Using new prologue blocks keeps the original CFG blocks unmodified; all rewriting is localized.

**Each `Yield` terminator** → replaced with:
1. `*state = FooState::Suspend_i { live_locals... }` — pack live locals into state
2. `Return Poll::Pending`

**The original `Return val`** → replaced with:
1. `*state = FooState::Done`
2. `Return Poll::Ready(val)`

**`ItemSource::Coroutine` tag** → removed. The rewritten `FunDecl` becomes `ItemSource::TopLevel`.

---

## Section 5: Aeneas and Lean

After `desugar_coroutines`, Aeneas sees only ordinary enums and ordinary functions. **No changes are required in Aeneas** (symbolic interpreter, pure translator, or extractor).

### Prelude types (Charon registration required)

`Poll<T>` and `Context` must be registered as builtin ADTs in Charon before `desugar_coroutines` runs, analogous to how `Option`/`Result`/`Box` are registered. This is a real implementation step.

- `Poll<T>` — generic ADT with two constructors: `Ready(T)` and `Pending`
- `Context` — opaque ADT, no observable fields; only threaded through to child `poll` calls

### `Poll` in Lean

Already added to `backends/lean/Aeneas/Std/Primitives.lean`:

```lean
/-- Mirrors `std::task::Poll`. -/
inductive Poll (α : Type u) where
  | ready   (v : α) : Poll α
  | pending          : Poll α
deriving Repr, DecidableEq
```

(`DecidableEq` is preferred over `BEq` for Lean proofs.)

`Context` is added as an opaque axiom:

```lean
opaque Context : Type
```

### Extracted Lean shape

For `async fn leaf() -> u32 { 3 }` (no await points — no suspension, no `Running` variant):

```lean
inductive LeafState where
  | start
  | done

def leaf_poll (state : LeafState) (ctx : Context) : Result (Poll UInt32 × LeafState) :=
  match state with
  | .done  => .ok (.panic, .done)    -- Abort(Panic)
  | .start => .ok (.ready 3, .done)
```

For `async fn caller() -> u32 { leaf().await + 1 }` (one await point):

```lean
inductive CallerState where
  | running
  | start
  | suspend0 (leafFuture : LeafState)
  | done

def caller_poll (state : CallerState) (ctx : Context) : Result (Poll UInt32 × CallerState) :=
  match state with
  | .running | .done => .ok (.panic, state)   -- Abort(Panic)
  | .start =>
    -- prologue: unpack Start (no upvars), proceed to poll child immediately
    let lf := LeafState.start
    match leaf_poll lf ctx with
    | .ok (.ready v, _)    => .ok (.ready (v + 1), .done)
    | .ok (.pending, lf')  => .ok (.pending, .suspend0 lf')
    | .error e             => .error e
  | .suspend0 lf =>
    match leaf_poll lf ctx with
    | .ok (.ready v, _)    => .ok (.ready (v + 1), .done)
    | .ok (.pending, lf')  => .ok (.pending, .suspend0 lf')
    | .error e             => .error e
```

No self-recursion in poll functions. Each call to `poll` is a single step; the "loop" of re-polling is the caller's responsibility.

### Proofs

The `progress` tactic requires no changes. `Poll` constructors are ordinary ADT constructors; `simp` reduces `match` on them. The `Running`/`Done` panic branches are discharged by `simp` (they reduce to `Abort`). Well-formed states are always `Start` or `Suspend_i`.

Termination of the poll loop (i.e., the child future eventually returns `Ready`) is a liveness property — a separate proof obligation, not a pipeline concern.

---

## Implementation Task Map

| Task | File(s) | Dependency |
|---|---|---|
| Add `CoroutineKind` enum | `types.rs` | — |
| Add `TypeDeclKind::Coroutine` | `types.rs` | CoroutineKind |
| Add `ItemSource::Coroutine` | `gast.rs` | TypeDeclRef |
| Add `TerminatorKind::Yield` + `CoroutineDrop` | `ullbc_ast.rs` | — |
| Register `Poll<T>`, `Context` as prelude ADTs | `translate_items.rs` or prelude init | — |
| Handle `TyKind::Coroutine` in `translate_types.rs` | `translate_types.rs` | TypeDeclKind::Coroutine |
| `translate_coroutine_adt` in `translate_items.rs` | `translate_items.rs` | TypeDeclKind::Coroutine |
| Tag coroutine body FunDecl | `translate_items.rs` | ItemSource::Coroutine |
| Unblock 4 rejection sites | `translate_bodies.rs` | Yield/CoroutineDrop variants |
| New `desugar_coroutines` ULLBC pass | new file + `transform/mod.rs` | All above |
| Update `ullbc_to_llbc.rs` (no Yield should arrive) | `ullbc_to_llbc.rs` | desugar_coroutines |
| Add `opaque Context` to `Primitives.lean` | `backends/lean/.../Primitives.lean` | — |
| Update `Poll` derive: `BEq` → `DecidableEq` | `backends/lean/.../Primitives.lean` | — |
| Add `async_basic.rs` test (remove `//@ skip`) | `tests/src/async_basic.rs` | All above |

All Charon changes are in the `charon/` subdirectory and require a Charon PR; the Aeneas-side changes are in `backends/lean/` and require a separate Aeneas PR (or can follow as a fast-follow).
