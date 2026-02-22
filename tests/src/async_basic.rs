//@ skip
//
// Step 0 probe: minimal async crate to find the first pipeline failure point.
//
// How to use this file:
//   1. Remove the `//@ skip` line above.
//   2. Ensure `make setup-charon` has been run (Charon pinned at 43459f88e30db00fd0dd839fd73b03e972149233).
//   3. Run: REGEN_LLBC=1 make test-async_basic.rs
//
// Expected outcome (as of the pinned Charon commit):
//   Charon fails to emit LLBC for async functions. Charon's LLBC AST has no
//   Coroutine / Generator / AsyncFn variants and `fun_decl` has no `is_async`
//   field. Async Rust is desugared to coroutines by rustc, and Charon does not
//   yet lower coroutine bodies to LLBC.
//
//   Once Charon gains async/coroutine support, re-enable this test and observe
//   the *second* failure point (likely in the Aeneas interpreter or Lean
//   extraction). See FUTURE_DIRECTION.md for the intended async roadmap.

/// A leaf async function that returns a plain value.
pub async fn leaf() -> u32 {
    3
}

/// An async function that awaits another.
pub async fn caller() -> u32 {
    leaf().await + 1
}
