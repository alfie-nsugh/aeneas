import Aeneas.Extract

namespace Aeneas.Std

-- Phase 2 entry point (SL layer for shared-state primitives)
-- ============================================================
-- These atomic types are intentionally left as opaque axioms for now.
-- Once iris-lean (https://github.com/leanprover-community/iris-lean) is added
-- as a dependency (backends/lean/lakefile.lean), each axiom below should be
-- replaced by a concrete definition backed by Iris invariants and ghost state,
-- so that operations like `fetch_add`, `compare_exchange`, etc. can be given
-- meaningful Hoare-triple specs of the form {{{ P }}} e {{{ v, Q v }}}.
--
-- Steps to implement Phase 2 here:
--   1. Add `require iris-lean from git ...` to backends/lean/lakefile.lean.
--   2. Define `AtomicBool` and `AtomicU32` as structures wrapping an Iris
--      `Auth`/`Frac` resource tracking the current value as a ghost resource.
--   3. Provide `AtomicU32.load_spec`, `AtomicU32.store_spec`,
--      `AtomicU32.fetch_add_spec`, `AtomicU32.compare_exchange_spec`, etc.
--      as Iris WP rules (the analogue of `U32.add_spec` for the SL layer).
--   4. Run `make extract-lean-std` to regenerate ExtractBuiltinLean.ml so
--      Aeneas maps `core::sync::atomic::AtomicU32` to the new definition.
--
-- Until then the axiom stubs let Aeneas codegen compile for code that merely
-- mentions these types without calling any atomic operations.
@[rust_type "core::sync::atomic::AtomicBool"]
axiom core.sync.atomic.AtomicBool : Type

-- TODO: see Phase 2 entry point comment above.
@[rust_type "core::sync::atomic::AtomicU32"]
axiom core.sync.atomic.AtomicU32 : Type

end Aeneas.Std
