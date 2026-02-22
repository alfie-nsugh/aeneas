# Charon Async Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Implement two-pass async lowering in Charon so that `async fn` + `.await` produce ordinary LLBC enums and functions that Aeneas can process without modification.

**Architecture:** Pass 1 faithfully translates coroutine MIR to ULLBC (new `Yield`/`CoroutineDrop` terminators, `TypeDeclKind::Coroutine`, `ItemSource::Coroutine`). Pass 2 (`desugar_coroutines` ULLBC pass) rewrites these into a concrete state machine enum (`Running|Start|Suspend_i|Done`) and an ordinary poll function. After Pass 2, the rest of the pipeline sees no async-specific nodes.

**Tech Stack:** Rust, Charon (charon/ subdirectory), Lean 4 (backends/lean/). Charon changes require their own PR to github.com/AeneasVerif/charon; Aeneas/Lean changes go in this repo.

**Design doc:** `docs/plans/2026-02-22-charon-async-design.md`

**Milestone 1 constraint:** Async without cancellation — coroutines with `CoroutineDrop` or `Yield.drop=Some(_)` are rejected with a clear error pointing to milestone 2.

---

## Part A: New AST Nodes (Charon PR)

These compile together — tasks 1–4 can be done in one commit since they're all additive.

---

### Task 1: Add `CoroutineKind` enum to `types.rs`

**Files:**
- Modify: `charon/charon/src/ast/types.rs` (after the existing `ClosureKind` enum)

**Step 1: Add the enum**

In `charon/charon/src/ast/types.rs`, find the `ClosureKind` enum and add `CoroutineKind` immediately after it:

```rust
/// The kind of a coroutine: async fn, generator, or async generator.
/// Used in `TypeDeclKind::Coroutine` to enable "narrow now, broad later" scope.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash,
    EnumIsA, EnumAsGetters,
    SerializeState, DeserializeState,
    Drive, DriveMut,
)]
pub enum CoroutineKind {
    /// An `async fn` or `async` block.
    Async,
    /// A `gen {}` generator (not yet supported past milestone 1).
    Gen,
    /// An `async gen {}` async generator (not yet supported past milestone 1).
    AsyncGen,
}
```

**Step 2: Verify it compiles**

```bash
cd /home/avi/aeneas/charon && cargo build -p charon-lib 2>&1 | head -40
```

Expected: no errors related to `CoroutineKind`.

**Step 3: Commit**

```bash
git add charon/src/ast/types.rs
git commit -m "feat(ast): add CoroutineKind enum"
```

---

### Task 2: Add `TypeDeclKind::Coroutine` to `types.rs`

**Files:**
- Modify: `charon/charon/src/ast/types.rs`

**Step 1: Add the variant**

In `TypeDeclKind` (line ~525), add `Coroutine` before `Opaque`:

```rust
/// An abstract coroutine type produced by `async fn`.
/// This is a placeholder: the `desugar_coroutines` ULLBC pass replaces it
/// with a concrete `TypeDeclKind::Enum` (Running|Start|Suspend_i|Done).
Coroutine {
    /// Async, Gen, or AsyncGen — enables "narrow now, broad later".
    kind: CoroutineKind,
    /// What the coroutine yields on suspension (for async fn: ()).
    yield_ty: Ty,
    /// The type of the resume argument (for async fn: ()).
    resume_ty: Ty,
    /// The return type (T in `async fn -> T`).
    output: Ty,
    /// Upvars captured from the enclosing scope.
    upvar_tys: Vec<Ty>,
},
```

**Step 2: Build to find all match exhaustiveness errors**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "non-exhaustive\|match.*Coroutine\|TypeDeclKind" | head -40
```

Expected: A list of `match` sites that need a new `Coroutine` arm. Add `Coroutine { .. } => { todo!("coroutine") }` (or an appropriate action) to each site. Do NOT add `Coroutine` arms to printer/visitor code that already has a wildcard `_` arm — those will handle it automatically.

**Step 3: Build clean**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

Expected: zero errors.

**Step 4: Commit**

```bash
git add charon/src/ast/types.rs
git commit -m "feat(ast): add TypeDeclKind::Coroutine placeholder variant"
```

---

### Task 3: Add `ItemSource::Coroutine` to `gast.rs`

**Files:**
- Modify: `charon/charon/src/ast/gast.rs`

**Step 1: Add the variant**

In the `ItemSource` enum (line ~124), add `Coroutine` after `Closure`:

```rust
/// This is the body of a coroutine (async fn). The body still contains
/// `TerminatorKind::Yield` terminators at this stage; the `desugar_coroutines`
/// ULLBC pass will rewrite it into an ordinary poll function and remove this tag.
Coroutine {
    /// The `TypeDeclId` of the coroutine state type registered in Pass 1.
    coroutine_ty: TypeDeclRef,
},
```

**Step 2: Build and fix exhaustiveness**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "non-exhaustive\|ItemSource" | head -30
```

Add `Coroutine { .. } => { todo!("coroutine") }` to each match site that doesn't have a wildcard arm.

**Step 3: Build clean**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

Expected: zero errors.

**Step 4: Commit**

```bash
git add charon/src/ast/gast.rs
git commit -m "feat(ast): add ItemSource::Coroutine variant"
```

---

### Task 4: Add `TerminatorKind::Yield` and `CoroutineDrop` to `ullbc_ast.rs`

**Files:**
- Modify: `charon/charon/src/ast/ullbc_ast.rs`

**Step 1: Add the variants**

In `TerminatorKind` (line ~97), add before `Abort`:

```rust
/// Suspend the coroutine, yielding a value to the caller.
/// On the next call (resume), execution jumps to `resume` with `resume_arg` set.
/// Only present before the `desugar_coroutines` ULLBC pass.
///
/// Mirrors rustc MIR's `TerminatorKind::Yield`.
Yield {
    /// Value produced at suspension. For `async fn`, always `()`.
    value: Operand,
    /// Place that receives the resume argument when execution is continued.
    resume_arg: Place,
    /// Block to jump to when the coroutine is resumed.
    resume: BlockId,
    /// Block to jump to if the coroutine is dropped while suspended.
    /// `None` means there is no drop-cleanup path for this suspension point.
    /// Milestone 1 rejects any `Yield` where this is `Some`.
    drop: Option<BlockId>,
},
/// Indicates the end of the coroutine's drop-glue body.
/// Semantically equivalent to `Return` from the drop shim.
/// Only present before the `desugar_coroutines` ULLBC pass.
///
/// Milestone 1 rejects any coroutine body that contains this terminator.
///
/// Mirrors rustc MIR's `TerminatorKind::CoroutineDrop`.
CoroutineDrop,
```

**Step 2: Build and fix exhaustiveness**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "non-exhaustive\|TerminatorKind\|Yield\|CoroutineDrop" | head -40
```

For each match site, add:
- `TerminatorKind::Yield { .. } => { todo!("coroutine yield") }`
- `TerminatorKind::CoroutineDrop => { todo!("coroutine drop") }`

The `ullbc_to_llbc.rs` pass in particular will need these arms — but since `desugar_coroutines` will run before it, these arms should be `unreachable!()` in `ullbc_to_llbc.rs` (we'll add a proper assertion in Task 16).

**Step 3: Build clean**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git add charon/src/ast/ullbc_ast.rs
git commit -m "feat(ast): add TerminatorKind::Yield and CoroutineDrop for pre-desugar ULLBC"
```

---

## Part B: Translation Layer / Pass 1 (Charon PR)

---

### Task 5: Handle `TyKind::Coroutine` in `translate_types.rs`

**Files:**
- Modify: `charon/charon/src/bin/charon-driver/translate/translate_types.rs`

**Context:** Line 280 currently has `hax::TyKind::Coroutine(..) => raise_error!(...)`. The closure pattern to follow is `hax::TyKind::Closure(args) => { let tref = self.translate_closure_type_ref(span, args)?; TyKind::Adt(tref) }` at line ~237.

**Step 1: Add `translate_coroutine_type_ref` method**

Find `impl ItemTransCtx` in `translate_types.rs` (or in a new file `translate_coroutines.rs`; modelling `translate_closures.rs`). Add:

```rust
/// Translate a reference to the coroutine state ADT.
/// Queues the coroutine's def_id for registration as:
/// - A `TypeDecl` (the abstract coroutine state type, later rewritten by `desugar_coroutines`)
/// - A coroutine body `FunDecl` (which `desugar_coroutines` rewrites into a poll function)
///
/// Mirrors `translate_closure_type_ref`.
pub fn translate_coroutine_type_ref(
    &mut self,
    span: Span,
    item_ref: &hax::ItemRef,
) -> Result<TypeDeclRef, Error> {
    self.translate_item(span, item_ref, TransItemSourceKind::Type)
    // Note: the coroutine body FunDecl is registered in translate_items.rs
    // when `translate_type_decl` encounters `FullDefKind::Closure` + `is_coroutine()`.
}
```

**Step 2: Replace the `raise_error!` at line ~280**

```rust
hax::TyKind::Coroutine(item_ref) => {
    // Treat the coroutine type as an opaque ADT reference for Pass 1.
    // `desugar_coroutines` will later replace TypeDeclKind::Coroutine
    // with a concrete state machine enum.
    let tref = self.translate_coroutine_type_ref(span, item_ref)?;
    TyKind::Adt(tref)
}
// TyKind::CoroutineClosure is out of scope for milestone 1.
// hax::TyKind::CoroutineClosure(..) => raise_error!(...) — leave unchanged.
```

**Step 3: Build and test with the probe crate**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git add charon/src/bin/charon-driver/translate/translate_types.rs
git commit -m "feat(translate): handle TyKind::Coroutine as opaque ADT ref (Pass 1)"
```

---

### Task 6: Add `translate_coroutine_adt` to `translate_items.rs`

**Files:**
- Modify: `charon/charon/src/bin/charon-driver/translate/translate_items.rs`

**Context:** `translate_type_decl` handles `FullDefKind::Closure { args, .. }` with `self.translate_closure_adt(span, args)`. For `async fn`, the anonymous coroutine type arrives here as `FullDefKind::Closure` (hax treats closures, coroutines, and coroutine-closures uniformly). We detect the coroutine case via `args.kind` or the MIR coroutine kind.

**Step 1: Add a helper to detect coroutines**

In `translate_items.rs`, find the `FullDefKind::Closure { args, .. }` arm in `translate_type_decl`. Before calling `translate_closure_adt`, add a branch:

```rust
FullDefKind::Closure { args, .. } => {
    if args.is_coroutine() {
        self.translate_coroutine_adt(span, args)?
    } else {
        self.translate_closure_adt(span, args)?
    }
}
```

Note: `args.is_coroutine()` — verify the exact API on `hax::ClosureArgs` in `charon/hax-frontend/src/types/new/full_def.rs`. The `ClosureKind` on args will be `Coroutine` for `async fn` bodies. If `ClosureArgs` doesn't expose `is_coroutine()`, check the `kind` field directly.

**Step 2: Implement `translate_coroutine_adt`**

```rust
/// Translate the anonymous coroutine type created by `async fn` into a
/// `TypeDeclKind::Coroutine` placeholder. The `desugar_coroutines` ULLBC pass
/// will later replace this with a concrete state machine enum.
fn translate_coroutine_adt(
    &mut self,
    span: Span,
    args: &hax::ClosureArgs,
) -> Result<TypeDeclKind, Error> {
    let yield_ty = self.translate_ty(span, &args.coroutine_yield_ty())?;
    let resume_ty = self.translate_ty(span, &args.coroutine_resume_ty())?;
    let output = self.translate_ty(span, &args.coroutine_return_ty())?;
    let upvar_tys = args
        .upvar_tys()
        .iter()
        .map(|ty| self.translate_ty(span, ty))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(TypeDeclKind::Coroutine {
        kind: CoroutineKind::Async,
        yield_ty,
        resume_ty,
        output,
        upvar_tys,
    })
}
```

Note: `args.coroutine_yield_ty()`, `args.coroutine_resume_ty()`, `args.coroutine_return_ty()` — verify the actual field/method names on `hax::ClosureArgs`. Look at how rustc's `CoroutineArgs` exposes these fields; hax should mirror them.

**Step 3: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git add charon/src/bin/charon-driver/translate/translate_items.rs
git commit -m "feat(translate): add translate_coroutine_adt for TypeDeclKind::Coroutine"
```

---

### Task 7: Tag coroutine body `FunDecl` with `ItemSource::Coroutine`

**Files:**
- Modify: `charon/charon/src/bin/charon-driver/translate/translate_items.rs`

**Context:** When a coroutine body is translated as a `FunDecl` (via `translate_fun_decl` for `FullDefKind::Closure` + `is_coroutine()`), we need to set `src: ItemSource::Coroutine { coroutine_ty }` instead of the closure item source.

**Step 1: Find where `translate_fun_decl` handles closures**

In `translate_items.rs`, find the `translate_fun_decl` path for `FullDefKind::Closure`. Add a coroutine branch:

```rust
FullDefKind::Closure { args, .. } if args.is_coroutine() => {
    // Retrieve the TypeDeclRef that was registered when translating
    // the return type of the outer async fn (via translate_coroutine_type_ref).
    let coroutine_ty: TypeDeclRef = self.get_already_registered_coroutine_type(span, args)?;
    // Tag this FunDecl as a coroutine body.
    // desugar_coroutines will rewrite it into a poll function and remove this tag.
    ItemSource::Coroutine { coroutine_ty }
}
```

The `get_already_registered_coroutine_type` helper retrieves the TypeDeclId that was registered by `translate_coroutine_type_ref` in Task 5. Look at how closures retrieve their type ref (via `translate_closure_type_ref`) to model this.

**Step 2: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 3: Commit**

```bash
git add charon/src/bin/charon-driver/translate/translate_items.rs
git commit -m "feat(translate): tag coroutine body FunDecl with ItemSource::Coroutine"
```

---

### Task 8: Unblock 4 rejection sites in `translate_bodies.rs`

**Files:**
- Modify: `charon/charon/src/bin/charon-driver/translate/translate_bodies.rs`

This task touches four separate `raise_error!` sites. Handle them one by one in the same commit.

**Step 1: `AggregateKind::Coroutine` (line ~785)**

Old:
```rust
AggregateKind::Coroutine(..) | AggregateKind::CoroutineClosure(..) => {
    raise_error!(self, span, "Coroutines are not supported")
}
```

New (split the two cases):
```rust
AggregateKind::Coroutine(args) => {
    // Placeholder constructor: "create coroutine with these upvars".
    // desugar_coroutines will rewrite this to the concrete Start variant constructor.
    let coroutine_ty = self.translate_coroutine_type_ref(span, &args.item)?;
    let upvar_args = args
        .upvar_tys()
        .iter()
        .zip(operands.iter())
        .map(|(ty, op)| -> Result<Operand, Error> {
            let _ = self.translate_ty(span, ty)?;
            self.translate_operand(span, op)
        })
        .try_collect()?;
    Rvalue::Aggregate(
        AggregateKind::Adt(coroutine_ty, None, None),
        upvar_args,
    )
}
AggregateKind::CoroutineClosure(..) => {
    raise_error!(self, span, "Coroutine closures (async closures) are not supported yet (milestone 2)")
}
```

**Step 2: `TerminatorKind::Yield` and `TerminatorKind::CoroutineDrop` (line ~980)**

Old:
```rust
TerminatorKind::CoroutineDrop | TerminatorKind::TailCall { .. } | TerminatorKind::Yield { .. } => {
    raise_error!(self, span, "Unsupported terminator: {:?}", terminator.kind)
}
```

New (split out Yield and CoroutineDrop from TailCall):
```rust
TerminatorKind::Yield { value, resume_arg, target, drop } => {
    let value = self.translate_operand(span, value)?;
    let resume_arg = self.translate_place(span, resume_arg)?;
    let resume = self.translate_basic_block_id(*target);
    let drop = drop.map(|b| self.translate_basic_block_id(b));
    TerminatorKind::Yield { value, resume_arg, resume, drop }
}
TerminatorKind::CoroutineDrop => TerminatorKind::CoroutineDrop,
TerminatorKind::TailCall { .. } => {
    raise_error!(self, span, "Unsupported terminator: {:?}", terminator.kind)
}
```

**Step 3: `AssertKind::ResumedAfter*` (line ~1239)**

Old:
```rust
AssertKind::ResumedAfterDrop(..) | AssertKind::ResumedAfterPanic(..) | AssertKind::ResumedAfterReturn(..) => {
    raise_error!(self, span, "Coroutines are not supported")
}
```

New — translate as a runtime panic assertion (not UB):
```rust
AssertKind::ResumedAfterReturn(_) | AssertKind::ResumedAfterDrop(_) | AssertKind::ResumedAfterPanic(_) => {
    // These checks fire when a coroutine is polled in an invalid state.
    // Translate as a runtime panic ("this is a programming error, not UB").
    // The condition that must hold is always `false` (these blocks are unreachable
    // in well-formed coroutines; desugar_coroutines ensures well-formedness).
    assert = Assert {
        cond: Operand::Const(Literal::Bool(false).into()),
        expected: true,
        msg: AssertMsg::Panic(String::from("polled coroutine in invalid state")),
    }
}
```

Note: match the exact `Assert` / `AssertMsg` types used elsewhere in this file.

**Step 4: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 5: Smoke test on async_basic.rs**

```bash
cd /home/avi/aeneas && make setup-charon
REGEN_LLBC=1 make test-async_basic.rs 2>&1 | head -60
```

After this task, the `async_basic.rs` probe crate should reach `desugar_coroutines` (which doesn't exist yet) or fall through to Aeneas (which will then fail). The important thing is that it no longer fails in `translate_types.rs`.

**Step 6: Commit**

```bash
git add charon/src/bin/charon-driver/translate/translate_bodies.rs
git commit -m "feat(translate): unblock 4 coroutine rejection sites in translate_bodies (Pass 1)"
```

---

### Task 9: Register `Poll<T>` and `Context` as Charon prelude ADTs

**Files:**
- Explore: `charon/charon/src/bin/charon-driver/translate/translate_crate.rs` (or wherever `Box`/`Option` are registered as known types)
- Modify: the relevant prelude/known-types registration file

**Context:** The `desugar_coroutines` pass inserts `Poll::Pending` and `Poll::Ready(val)` constructors into the rewritten function bodies. These types must exist in the `TranslatedCrate` before that pass runs. The pattern to follow is how Charon registers `std::boxed::Box`, `std::option::Option`, and `std::result::Result` as known types.

**Step 1: Find where builtins are registered**

```bash
grep -r "Box\|Option\|known_type\|prelude\|builtin.*Type" \
  charon/src/bin/charon-driver/translate/ --include="*.rs" -l
```

Read the relevant file to understand the registration API.

**Step 2: Register `core::task::Poll<T>` and `core::task::Context`**

Using the same mechanism as `Box`/`Option`:
- `core::task::Poll<T>` — generic ADT, two variants: `Ready(T)` and `Pending`
- `core::task::Context` — opaque ADT, no fields

Store the registered `TypeDeclId` values for use by `desugar_coroutines` in Task 10.

**Step 3: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git commit -m "feat(translate): register Poll<T> and Context as Charon prelude ADTs"
```

---

## Part C: `desugar_coroutines` Pass (Charon PR)

This is the most complex part. Split into four tasks to keep each one reviewable.

---

### Task 10: Pass skeleton + scope guards

**Files:**
- Create: `charon/charon/src/transform/normalize/desugar_coroutines.rs`
- Modify: `charon/charon/src/transform/normalize/mod.rs` (add `pub mod desugar_coroutines;`)
- Modify: `charon/charon/src/transform/mod.rs` (register pass in `ULLBC_PASSES`)

**Step 1: Create the pass file**

```rust
//! Desugar coroutine bodies into ordinary state machines.
//!
//! This pass runs on every `FunDecl` tagged `ItemSource::Coroutine`.
//! It replaces the `TypeDeclKind::Coroutine` abstract type with a concrete
//! `TypeDeclKind::Enum` (Running | Start | Suspend_i | Done) and rewrites
//! the coroutine body into an ordinary poll function.
//!
//! **Milestone 1 constraint:** coroutines with `CoroutineDrop` or
//! `Yield.drop = Some(_)` are rejected (async without cancellation).

use super::super::ctx::UllbcPass;
use crate::{
    errors::error_or_panic,
    transform::TransformCtx,
    ullbc_ast::*,
};

pub struct Transform;

impl UllbcPass for Transform {
    fn name(&self) -> &str {
        "desugar_coroutines"
    }

    fn transform_ctx(&self, ctx: &mut TransformCtx) {
        // Collect the IDs of coroutine FunDecls to avoid borrow issues.
        let coroutine_ids: Vec<FunDeclId> = ctx
            .translated
            .fun_decls
            .iter()
            .filter_map(|(id, decl)| {
                if matches!(decl.src, ItemSource::Coroutine { .. }) {
                    Some(id)
                } else {
                    None
                }
            })
            .collect();

        for id in coroutine_ids {
            let decl = ctx.translated.fun_decls.get_mut(id).unwrap();
            self.desugar_coroutine(ctx, decl);
        }
    }

    // Individual bodies are handled via transform_ctx above.
    fn transform_function(&self, _ctx: &mut TransformCtx, _decl: &mut FunDecl) {}
}

impl Transform {
    fn desugar_coroutine(&self, ctx: &mut TransformCtx, decl: &mut FunDecl) {
        let span = decl.item_meta.span;
        let body = match decl.body.as_unstructured_mut() {
            Some(b) => b,
            None => return,
        };

        // === Step 0: Scope guards ===
        // Reject anything that requires cancellation/drop semantics.
        for block in body.body.iter() {
            // Reject CoroutineDrop terminator
            if matches!(block.terminator.kind, TerminatorKind::CoroutineDrop) {
                error_or_panic!(
                    ctx,
                    span,
                    "Coroutine drop glue is not supported in milestone 1. \
                     This coroutine contains a `CoroutineDrop` terminator, which \
                     is generated when a future needs drop-while-pending semantics. \
                     See milestone 2 in docs/plans/2026-02-22-charon-async-design.md"
                );
                return;
            }
            // Reject Yield with a drop target
            if let TerminatorKind::Yield { drop: Some(_), .. } = &block.terminator.kind {
                error_or_panic!(
                    ctx,
                    span,
                    "Coroutine cancellation (Yield.drop) is not supported in milestone 1. \
                     See milestone 2 in docs/plans/2026-02-22-charon-async-design.md"
                );
                return;
            }
        }

        // Steps 1–4 will be added in Tasks 11–14.
        todo!("desugar_coroutines steps 1-4 not yet implemented")
    }
}
```

**Step 2: Register in `normalize/mod.rs`**

```rust
pub mod desugar_coroutines;
```

**Step 3: Register in `transform/mod.rs` ULLBC_PASSES**

Add after the existing cleanup passes and before `ullbc_to_llbc`:

```rust
// Desugar coroutine bodies (async fn) into ordinary state machine enums + poll functions.
// Must run after insert_storage_lives (so StorageLive/Dead are present for liveness)
// and before ullbc_to_llbc (which must not see Yield terminators).
UnstructuredBody(&normalize::desugar_coroutines::Transform),
```

Place it near the end of `ULLBC_PASSES`, after `update_block_indices` and before `LLBC_PASSES` begins.

**Step 4: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 5: Commit**

```bash
git add charon/src/transform/normalize/desugar_coroutines.rs \
        charon/src/transform/normalize/mod.rs \
        charon/src/transform/mod.rs
git commit -m "feat(transform): add desugar_coroutines pass skeleton with scope guards"
```

---

### Task 11: `desugar_coroutines` — Steps 1 & 2 (collect yields + liveness)

**Files:**
- Modify: `charon/charon/src/transform/normalize/desugar_coroutines.rs`

**Step 1: Collect and number suspension points (deterministic order)**

Replace the `todo!` in `desugar_coroutine` with:

```rust
// === Step 1: Collect suspension points in deterministic postorder ===
// We use postorder (from entry block), breaking ties by BlockId,
// for stable variant numbering across upstream changes.
let yield_points: Vec<(BlockId, /* yield_index */ usize)> = {
    let mut visited = std::collections::HashSet::new();
    let mut postorder: Vec<BlockId> = Vec::new();

    fn postorder_dfs(
        id: BlockId,
        body: &BodyContents,
        visited: &mut std::collections::HashSet<BlockId>,
        out: &mut Vec<BlockId>,
    ) {
        if !visited.insert(id) { return; }
        let block = &body[id];
        // Visit successors first (postorder)
        for succ in block.terminator.kind.targets() {
            postorder_dfs(succ, body, visited, out);
        }
        out.push(id);
    }

    postorder_dfs(START_BLOCK_ID, &body.body, &mut visited, &mut postorder);
    postorder.reverse(); // reverse postorder = topological-ish order

    postorder
        .iter()
        .filter(|&&id| {
            matches!(body.body[id].terminator.kind, TerminatorKind::Yield { .. })
        })
        .enumerate()
        .map(|(idx, &id)| (id, idx))
        .collect()
};
```

Note: `TerminatorKind::targets()` — check if this method exists; if not, implement a local helper that returns `[resume, drop.unwrap_or(resume)]` for `Yield` and the standard targets for other terminators.

**Step 2: Liveness analysis**

```rust
// === Step 2: Liveness analysis ===
// Compute, for each yield_i, the set of ULLBC locals live across that point.
// A local is live-out of a block if it is defined before and used after resumption.
//
// TEMPORARY: We use StorageLive/Dead as a conservative upper bound.
// TODO(milestone 2): replace with true backwards dataflow.
// This over-approximation stores more locals than necessary but is always correct.
use std::collections::{HashMap, HashSet};

let num_locals = body.locals.locals.len();

// Collect StorageLive/Dead info: for each block, which locals have StorageLive
// at the block entry (conservative: if StorageLive was seen anywhere before this point).
// Simplification: collect all locals that are StorageLive at any point before each yield.
let live_at_yield: HashMap<usize, HashSet<LocalId>> = {
    let mut result = HashMap::new();
    for (yield_block_id, yield_idx) in &yield_points {
        // Conservative: any local that has a StorageLive statement anywhere in the body
        // and is not the return value or a function argument.
        // A more precise analysis would track reachability, but this is correct.
        let mut live = HashSet::new();
        for block in body.body.iter() {
            for stmt in &block.statements {
                if let StatementKind::StorageLive(local_id) = stmt.kind {
                    // Include all locals except _0 (return) and args
                    if local_id.index() > body.locals.arg_count {
                        live.insert(local_id);
                    }
                }
            }
        }
        result.insert(*yield_idx, live);
    }
    result
};
```

**Step 3: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git add charon/src/transform/normalize/desugar_coroutines.rs
git commit -m "feat(transform): desugar_coroutines steps 1-2: yield collection and liveness"
```

---

### Task 12: `desugar_coroutines` — Step 3 (generate state enum)

**Files:**
- Modify: `charon/charon/src/transform/normalize/desugar_coroutines.rs`

**Step 1: Build the variant list**

Add to `desugar_coroutine`, after the liveness analysis:

```rust
// === Step 3: Generate state enum ===
// Replace TypeDeclKind::Coroutine { .. } with TypeDeclKind::Enum.

let ItemSource::Coroutine { coroutine_ty } = &decl.src else {
    unreachable!()
};
let type_decl_id = coroutine_ty.id;

let has_yields = !yield_points.is_empty();

let mut variants: IndexVec<VariantId, Variant> = IndexVec::new();

// Running variant (only when there are suspension points)
if has_yields {
    variants.push(Variant {
        span,
        attr_info: AttrInfo::default(),
        name: VariantName("Running".to_string()),
        fields: IndexVec::new(),
        discriminant: Literal::Int(Integer { value: 0, is_signed: false }),
    });
}

// Start variant (holds upvars)
let upvar_fields: IndexVec<FieldId, Field> = {
    let TypeDeclKind::Coroutine { upvar_tys, .. } =
        &ctx.translated.type_decls[type_decl_id].kind
    else { unreachable!() };
    upvar_tys.iter().enumerate().map(|(i, ty)| Field {
        span,
        attr_info: AttrInfo::default(),
        name: Some(FieldName(format!("upvar_{i}"))),
        ty: ty.clone(),
    }).collect()
};
variants.push(Variant {
    span,
    attr_info: AttrInfo::default(),
    name: VariantName("Start".to_string()),
    fields: upvar_fields,
    discriminant: Literal::Int(Integer { value: 1, is_signed: false }),
});

// Suspend_i variants (one per yield point)
for (yield_block_id, yield_idx) in &yield_points {
    let live = &live_at_yield[yield_idx];
    let fields: IndexVec<FieldId, Field> = live.iter().map(|&local_id| {
        let local = &body.locals.locals[local_id];
        Field {
            span,
            attr_info: AttrInfo::default(),
            name: Some(FieldName(format!(
                "local_{}",
                local.name.clone().unwrap_or_else(|| local_id.index().to_string())
            ))),
            ty: local.ty.clone(),
        }
    }).collect();
    variants.push(Variant {
        span,
        attr_info: AttrInfo::default(),
        name: VariantName(format!("Suspend{yield_idx}")),
        fields,
        discriminant: Literal::Int(Integer {
            value: (yield_idx + 2) as u128,
            is_signed: false,
        }),
    });
}

// Done variant
variants.push(Variant {
    span,
    attr_info: AttrInfo::default(),
    name: VariantName("Done".to_string()),
    fields: IndexVec::new(),
    discriminant: Literal::Int(Integer {
        value: (yield_points.len() + 2) as u128,
        is_signed: false,
    }),
});

// Replace the TypeDeclKind::Coroutine with the concrete enum
ctx.translated.type_decls[type_decl_id].kind = TypeDeclKind::Enum(variants);
```

Note: Adjust `Variant`, `Field`, `VariantName`, `FieldName`, `AttrInfo`, `Literal` types to match what is actually in scope in Charon. Look at `charon/src/ast/types.rs` for the exact field names.

**Step 2: Rewrite the placeholder coroutine aggregate constructor**

In the same function, add a pass over the body to rewrite `AggregateKind::Adt(tref, None, None, upvars)` → `AggregateKind::Adt(tref, Some(start_variant_id), None, upvars)` for the coroutine type:

```rust
// Rewrite the placeholder constructor (built in translate_bodies)
// to use the concrete Start variant.
let start_variant_id = VariantId::from_usize(if has_yields { 1 } else { 0 });

for block in body.body.iter_mut() {
    for stmt in block.statements.iter_mut() {
        if let StatementKind::Assign(_, Rvalue::Aggregate(AggregateKind::Adt(tref, None, None), _)) = &mut stmt.kind {
            if tref.id == type_decl_id {
                // Replace None variant with Start
                if let StatementKind::Assign(_, Rvalue::Aggregate(AggregateKind::Adt(_, ref mut variant), _)) = &mut stmt.kind {
                    *variant = Some(start_variant_id);
                }
            }
        }
    }
}
```

**Step 3: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 4: Commit**

```bash
git add charon/src/transform/normalize/desugar_coroutines.rs
git commit -m "feat(transform): desugar_coroutines step 3: generate concrete state enum"
```

---

### Task 13: `desugar_coroutines` — Step 4 (rewrite poll function)

**Files:**
- Modify: `charon/charon/src/transform/normalize/desugar_coroutines.rs`

This is the most complex task. Add to `desugar_coroutine`:

**Step 1: Build prologue blocks**

For each `Suspend_i` variant, generate a new prologue block that:
1. Sets `*state = Running`
2. Moves fields out from the variant into locals
3. Jumps to the original `Yield.resume` block

```rust
// === Step 4: Rewrite the coroutine body into a poll function ===

// Build prologue blocks: one per suspension point, plus one for Start.
// Prologue protocol:
//   1. tmp = move *state         (consume the old variant)
//   2. *state = Running          (mark in-progress; re-entrant poll → dispatch hits Running)
//   3. restore locals from tmp.Suspend_i fields
//   4. goto original_resume_target
//
// For Start:
//   1. tmp = move *state
//   2. *state = Running
//   3. unpack upvars into locals
//   4. goto original_entry_block (START_BLOCK_ID from before we added the dispatch)

// ... (see full implementation in design doc)
// The exact ULLBC block construction API mirrors BodyBuilder in ullbc_ast_utils.rs
```

Note: Study `charon/src/ast/ullbc_ast_utils.rs` (the `BodyBuilder` struct) and existing passes that generate new blocks (e.g. `desugar_drops.rs`, `duplicate_return.rs`) to understand the block construction API.

**Step 2: Build entry dispatch block**

Replace the original entry block with a `Switch` on `discriminant(*state)`:
- `Running` → new block with `Assert { cond: false, on_failure: Abort(Panic) }`
- `Done` → new block with `Assert { cond: false, on_failure: Abort(Panic) }`
- `Start` → prologue block for Start
- `Suspend_i` → prologue block `P_i`

**Step 3: Rewrite each `Yield` terminator**

For each `Yield { value, resume_arg, resume, .. }` block:
1. Add before-terminator statement: `*state = FooState::Suspend_i { live_locals... }`
2. Replace terminator with `Return Poll::Pending`

**Step 4: Rewrite the `Return val` terminator**

For each block with `TerminatorKind::Return`:
1. Add before-terminator statement: `*state = FooState::Done`
2. Replace `Return val` with `Return Poll::Ready(val)`

**Step 5: Update the function signature**

Change the return type from `Coroutine_output_ty` to `Poll<output_ty>` and add `state: &mut FooState` + `ctx: &mut Context` parameters.

**Step 6: Remove `ItemSource::Coroutine` tag**

```rust
decl.src = ItemSource::TopLevel;
```

**Step 7: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 8: Commit**

```bash
git add charon/src/transform/normalize/desugar_coroutines.rs
git commit -m "feat(transform): desugar_coroutines step 4: rewrite coroutine into poll function"
```

---

### Task 14: Update `ullbc_to_llbc.rs` — assert no `Yield` arrives

**Files:**
- Modify: `charon/charon/src/transform/control_flow/ullbc_to_llbc.rs`

**Context:** After `desugar_coroutines` runs, no `Yield` or `CoroutineDrop` terminators should reach `ullbc_to_llbc`. Replace any `todo!()` or `unreachable!()` arms added in Task 4 with proper assertions.

**Step 1: Find the match arms for `Yield` and `CoroutineDrop` added in Task 4**

Replace `todo!("coroutine yield")` / `todo!("coroutine drop")` with:

```rust
TerminatorKind::Yield { .. } => {
    // desugar_coroutines must run before ullbc_to_llbc and eliminate all Yield terminators.
    panic!(
        "BUG: Yield terminator reached ullbc_to_llbc. \
         This means desugar_coroutines did not run or failed silently."
    )
}
TerminatorKind::CoroutineDrop => {
    panic!(
        "BUG: CoroutineDrop terminator reached ullbc_to_llbc. \
         This means desugar_coroutines did not run or failed silently."
    )
}
```

**Step 2: Build**

```bash
cd /home/avi/aeneas/charon && cargo build 2>&1 | grep "^error" | head -20
```

**Step 3: Commit**

```bash
git add charon/src/transform/control_flow/ullbc_to_llbc.rs
git commit -m "fix(transform): assert Yield/CoroutineDrop do not reach ullbc_to_llbc"
```

---

## Part D: End-to-End Test (Charon PR)

---

### Task 15: Smoke test with `async_basic.rs`

**Step 1: Run Charon on the probe crate**

From the Aeneas repo root:

```bash
cd /home/avi/aeneas
make setup-charon
REGEN_LLBC=1 make test-async_basic.rs 2>&1 | tee /tmp/async_basic_test.log
head -80 /tmp/async_basic_test.log
```

Expected outcome at this point: Charon runs without error on `async_basic.rs` and produces a `.llbc` file. Aeneas may then fail (we expect ordinary enum + function, which it should be able to handle).

**Step 2: Inspect the `.llbc` output**

```bash
cat tests/llbc/async_basic.llbc | head -100
```

Verify:
- `LeafState` appears as an enum with `Start` and `Done` variants
- `leaf_poll` appears as an ordinary function returning `Poll<u32>`
- No `TypeDeclKind::Coroutine` in the output
- No `Yield` terminators in the output

**Step 3: If Aeneas also succeeds — update the test file**

If `make test-async_basic.rs` passes end-to-end (Charon + Aeneas + Lean compilation):

In `tests/src/async_basic.rs`, change `//@ skip` to the normal headers and add a `//@ known-failure` if Lean proof obligations are expected to fail:

```rust
//@ [lean] aeneas-args=-backend lean
// Milestone 1: async fn without cancellation/drop-while-pending.
// This file is the Step 0 probe crate described in docs/plans/2026-02-22-charon-async-design.md
pub async fn leaf() -> u32 { 3 }
pub async fn caller() -> u32 { leaf().await + 1 }
```

**Step 4: Commit**

```bash
git add tests/src/async_basic.rs
git commit -m "test: enable async_basic.rs probe test (//@ skip removed)"
```

---

## Part E: Aeneas/Lean Backend (Aeneas PR)

These are small, fast-follow changes that are independent of the Charon PR.

---

### Task 16: Fix `Poll` derive — `BEq` → `DecidableEq`

**Files:**
- Modify: `backends/lean/Aeneas/Std/Primitives.lean`

**Step 1: Find and update the Poll definition**

The `Poll` type was added in a prior session. Find it:

```bash
grep -n "inductive Poll\|BEq\|DecidableEq" backends/lean/Aeneas/Std/Primitives.lean
```

Change the `deriving` line from:

```lean
deriving Repr, BEq
```

to:

```lean
deriving Repr, DecidableEq
```

**Step 2: Verify Lean builds**

```bash
cd backends/lean && lake build Aeneas 2>&1 | tail -20
```

Expected: zero errors.

**Step 3: Commit**

```bash
git add backends/lean/Aeneas/Std/Primitives.lean
git commit -m "fix(lean): Poll derive BEq → DecidableEq for proof-friendliness"
```

---

### Task 17: Add `opaque Context` axiom to `Primitives.lean`

**Files:**
- Modify: `backends/lean/Aeneas/Std/Primitives.lean`

**Step 1: Add after the `Poll` definition**

```lean
/-!
# Async Context
-/

/-- Opaque representation of `std::task::Context<'_>`.
    For verification purposes: never inspected, only threaded through `poll` calls.
    A real model (e.g. for waker reasoning) would go in a Phase 2 separation logic layer. -/
opaque Context : Type
```

**Step 2: Verify Lean builds**

```bash
cd backends/lean && lake build Aeneas 2>&1 | tail -20
```

**Step 3: Commit**

```bash
git add backends/lean/Aeneas/Std/Primitives.lean
git commit -m "feat(lean): add opaque Context axiom for async poll verification"
```

---

### Task 18: Update project memory

**Files:**
- Modify: `/home/avi/.claude/projects/-home-avi-aeneas/memory/MEMORY.md`

Update the async section to reflect that the implementation plan is complete and summarize the key file locations:

```markdown
### Implementation Plan Location
`docs/plans/2026-02-22-charon-async-impl.md` — full bite-sized task list
Key Charon files changed: `ast/types.rs`, `ast/gast.rs`, `ast/ullbc_ast.rs`,
`translate/translate_types.rs`, `translate/translate_items.rs`,
`translate/translate_bodies.rs`, `transform/normalize/desugar_coroutines.rs`
```

---

## Dependency Graph

```
Task 1 (CoroutineKind)
  └── Task 2 (TypeDeclKind::Coroutine)
        ├── Task 5 (translate_types.rs)
        └── Task 6 (translate_coroutine_adt)

Task 3 (ItemSource::Coroutine)
  └── Task 7 (tag FunDecl)

Task 4 (Yield/CoroutineDrop terminators)
  └── Task 8 (translate_bodies.rs)
  └── Task 14 (ullbc_to_llbc.rs assertions)

Tasks 2+3+4+5+6+7+8+9 → all complete →
  Task 10 (pass skeleton)
    └── Task 11 (steps 1-2)
          └── Task 12 (step 3: state enum)
                └── Task 13 (step 4: poll function)
                      └── Task 14 (assert no Yield in ullbc_to_llbc)
                            └── Task 15 (smoke test)

Tasks 16+17 (Lean backend) — independent, no blockers
Task 18 (memory update) — after Task 15
```
