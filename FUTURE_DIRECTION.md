Right now the **Lean backend** of Aeneas is built around:

* generating *shallowly embedded* Lean code like `def f … : Result α := do …` (a `Result` monad with `ok/fail/div`) ([GitHub][1])
* proving things using a simple WP-style predicate `Std.WP.spec (m : Result α) (post : α → Prop)` with the `⦃ … ⦄` notation ([GitHub][2])
* automation via the `progress` tactic, which is explicitly wired to goals of the shape `Std.WP.spec …` and to “progress the next monadic bind”. ([GitHub][3])

Also: Aeneas currently models **sequential safe Rust only**; concurrency is explicitly out-of-scope today, with SL intended as the path to lift that. ([arXiv][4])

So if you want “Lean-Iris + async”, the Lean backend needs to change *what it generates* (program representation + spec representation) and *what the tactics target*.

Below are the two realistic backend directions, and what “modifying the backend” concretely means in each.

---

## Direction A (easier first step): async **without** true concurrency, keep shallow embedding

This treats `async` as **a state machine** (which is what Rust compiles it to), but *not* as an interleaving concurrent system.

### What the backend would generate differently

1. **Generate a `Poll`-based interface instead of direct `Result`:**

   * add a Lean type like:

     * `inductive Poll (α) | Ready (a:α) | Pending`
   * for each `async fn foo(args) -> T`, generate something like:

     * `def foo_poll : FooState → Ctx → Result (Poll T × FooState)`
     * and maybe a wrapper `def foo_run : … → Result T` that repeatedly polls (with a fuel parameter).

2. **Lower every `.await` into an explicit `poll` loop:**

   * `.await` becomes: call `bar_poll`, case-split on `Ready/Pending`, update the state, return `Pending` if needed.

3. **Proof side stays close to today’s `Std.WP.spec`**

   * Specs become about `foo_run` or about invariants preserved across `foo_poll` steps.
   * The existing `progress` tactic can often still work, because you’re still in `Result` and still using `Std.WP.spec`. ([GitHub][2])

**What this buys you:** you can prove functional correctness of async code that is basically “pause/resume”, but you are *not* proving properties that depend on interleavings with other tasks.

---

## Direction B (the “Lean-Iris” direction): model concurrency + use Iris WP

This is the “real” CSL route: once tasks can interleave and share resources, you want Iris-style reasoning.

`iris-lean` gives you MoSeL + base logic scaffolding ([GitHub][5]), but you still need a *language instance* (expressions, state, step relation) and a `WP` for it.

### What the backend must change (in detail)

### 1) Stop generating plain Lean functions as “the program”

Iris WP is typically over an **object language** (a deep embedding) with a small-step semantics.

So instead of emitting:

```lean
def f (x : U32) : Result U32 := do …
```

the backend would emit *terms in an AST*, e.g.:

```lean
def f : Expr := -- AST for the function body
```

and/or:

```lean
def f (x : Val) : Expr := …
```

Concretely, you need new core types in the Lean runtime library:

* `Expr`, `Val`, `State`
* a step relation `step : (Expr × State) → (Expr × State) → Prop` (or a `prim_step`-style relation)

That’s a **backend contract change**: every codegen case (let-binding, match, calls, loops) must output AST constructors instead of executable Lean code.

### 2) Replace `Std.WP.spec` with Iris `WP` (iProp-valued)

Today Aeneas uses:

* `Std.WP.spec : Result α → (α → Prop) → Prop` ([GitHub][2])

In Iris you want something like:

* `WP e Φ : iProp` (postcondition lives in separation logic assertions, not `Prop`)

So the backend must:

* emit specs as Iris triples (notation varies), roughly:

  `{{{ P }}} e {{{ v, Q v }}}`

where `P` and `Q` are `iProp` (resource assertions), not plain propositions.

This also implies:

* your existing `[progress]` library of lemmas must be duplicated/replaced by Iris-typed versions (they won’t typecheck otherwise).

### 3) Rebuild the “progress” story as WP-step automation

Your current `progress` is specialized to “next `Result.bind` under `Std.WP.spec`”. ([GitHub][3])
For Iris, you need a new tactic (or a reworked `progress`) that:

* recognizes the next evaluation context inside `WP`,
* applies the right WP rule (`wp_bind`, `wp_pure`, `wp_load`, `wp_store`, `wp_cas`, `wp_spawn`, …),
* and introduces the right hypotheses (invariant-opening/closing, ownership transfers).

So “modify backend” includes “modify proof automation” because generated proofs/scripts rely on it.

### 4) Add concurrency primitives *as language constructs + proof rules*

To support async in a concurrent setting you need object-language primitives like:

* task spawn: `Spawn : Expr → Expr` (returns a handle)
* await/join: `Join : Handle → Expr`
* yield / suspension: depends how you model async (either explicit `Yield` or via `Poll/Pending`)
* atomics / mutex / channels: either as primitives, or as libraries encoded via heap + invariants

Then you must provide Iris specs/rules for them in Lean (this is the “stdlib” part Aeneas imports, similar to how `U32.add_spec` exists today). ([GitHub][6])
Right now, e.g. atomics/pin are still stubs/axioms in the Lean model ([GitHub][7]) — for real async/concurrency those have to become meaningful.

### 5) Decide how Rust’s “async lowering” maps to your language

You have two common encodings:

**(i) Generator/state-machine encoding**

* each future is a heap-allocated state + a `poll` function
* `.await` is “poll child; if pending, return pending; else continue”

**(ii) Direct “spawn/yield/join” calculus**

* you treat `.await` as “block until done” (or yield until ready)
* closer to structured concurrency calculi

Whichever you choose, the backend needs explicit codegen cases for:

* coroutine locals captured into state
* resume points / discriminant
* “pending” returns

### 6) (Important) Keep Aeneas’s borrow/ownership story consistent

Aeneas’s big trick is eliminating low-level memory reasoning for safe Rust by a value-based functional model. ([Lean Language][8])
If you jump to an Iris heap language too early, you may lose that advantage unless you:

* either keep safe Rust in the existing functional translation and only use Iris around “shared-state primitives”, **or**
* re-embed Aeneas’s “loan/borrow” resources as Iris resources (ghost state) so you still get ergonomic reasoning.

That’s exactly why Aeneas frames SL as “ongoing work” for unsafe + concurrency. ([GitHub][9])

---

## A practical incremental backend plan (what I’d actually do)

If the goal is “support async soon” without rewriting the world:

1. **Phase 1:** implement Direction A (async = state machine) in the existing Lean backend

   * still outputs `Result …` and uses `Std.WP.spec`
   * adds `Poll`, `*_poll` functions, and `.await` lowering

2. **Phase 2:** introduce a *separation-logic layer only for shared-state primitives*

   * keep most code as today’s functional model
   * model `Mutex/Atomic/Channel/Spawn` as abstract ops with SL-flavored specs
   * this gets you meaningful concurrency reasoning without fully deep-embedding *everything*

3. **Phase 3:** if needed, move to full Iris WP + deep embedding for end-to-end concurrency adequacy.

That aligns with the current Aeneas direction (“SL to support unsafe + concurrency”). ([GitHub][9])

---

If you tell me which async subset you care about first (single-thread executor? `tokio::spawn` + `JoinHandle`? channels? `Arc<Mutex<_>>`?), I can sketch the **exact minimal set of new generated constructs + new `[progress]`-style rules** you’d need for that subset.

[1]: https://raw.githubusercontent.com/AeneasVerif/aeneas/main/backends/lean/Aeneas/Std/Primitives.lean "raw.githubusercontent.com"
[2]: https://raw.githubusercontent.com/AeneasVerif/aeneas/main/backends/lean/Aeneas/Std/WP.lean "raw.githubusercontent.com"
[3]: https://raw.githubusercontent.com/AeneasVerif/aeneas/main/backends/lean/Aeneas/Progress/Progress.lean "raw.githubusercontent.com"
[4]: https://arxiv.org/pdf/2601.19207?utm_source=chatgpt.com "Refactoring and Equivalence in Rust"
[5]: https://github.com/leanprover-community/iris-lean?utm_source=chatgpt.com "leanprover-community/iris-lean"
[6]: https://raw.githubusercontent.com/AeneasVerif/aeneas/main/tests/lean/BaseTutorial.lean "raw.githubusercontent.com"
[7]: https://raw.githubusercontent.com/AeneasVerif/aeneas/main/backends/lean/Aeneas/Std/Core/Atomic.lean "raw.githubusercontent.com"
[8]: https://lean-lang.org/use-cases/aeneas/?utm_source=chatgpt.com "Aeneas: Bridging Rust to Lean for Formal Verification"
[9]: https://github.com/AeneasVerif/aeneas "GitHub - AeneasVerif/aeneas: A verification toolchain for Rust programs"


Yep — the fastest way to start is: **get Aeneas building + run the Lean backend end-to-end on a tiny crate**, *then* introduce a tiny `async` crate and see exactly where it breaks. That gives you a concrete first TODO instead of designing in the abstract.

## 0) Clone + build (known-good path)

The Aeneas README’s “happy path” is: OCaml 5 + opam deps, then `make setup-charon`, then `make`. ([GitHub][1])

### Option A: Nix (usually the least pain)

Aeneas explicitly supports a Nix quick-start, including running the exact pinned Charon version. ([GitHub][1])
If you already have Nix, this is worth doing first.

### Option B: opam + make

From the README: create an OCaml 5 switch, install deps, then `make setup-charon`, then `make`, then `make test`. ([GitHub][1])

(If you’re on Windows, I’d do this inside WSL2 or a Linux dev container.)

---

## 1) Verify you can generate Lean from *any* crate

Before touching async:

1. Pick a simple Rust crate (or one of their examples/tests).
2. Generate LLBC with:

```bash
charon cargo --preset=aeneas
```

(That preset is required per README.) ([GitHub][1])

3. Run Aeneas Lean backend:

```bash
./bin/aeneas -backend lean path/to/crate.llbc -split-files
```

(`-split-files` is handy because it generates “external template” stubs instead of failing hard when models are missing.) ([GitHub][1])

4. Put the generated Lean files into a fresh `lake new` project and add the local Aeneas Lean stdlib as a dependency, exactly like the README describes. ([GitHub][1])

This step makes sure your environment + Lean toolchain are correct *before* you debug async semantics.

---

## 2) Create a minimal async “probe” crate and see how far it gets

Create something tiny like:

* `async fn leaf() -> u32 { 3 }`
* `async fn uses_await() -> u32 { leaf().await + 1 }`

Then run the same pipeline (Charon → LLBC → Aeneas Lean).

**Goal:** capture the *first failure point*:

* Does **Charon** emit LLBC for async/coroutines?
* Does **Aeneas** reject the LLBC as “unsupported construct”?
* Or does it translate, but the Lean side fails?

That tells you whether you must start in **Charon** (IR support) or in **Aeneas** (translation/backend).

---

## 3) Where to look in the repo (and what to paste here)

From the repo top-level, the key directories are: `src/` (OCaml), `backends/` (Lean/Coq/etc stdlibs + tactics), `tests/` (generated outputs + proof scripts). ([GitHub][1])

To help you quickly, paste **these command outputs** (not screenshots):

```bash
# 1) high-level structure
ls
ls src
ls backends
ls backends/lean

# 2) find the Lean codegen / printers / backend dispatch
rg -n "backend.*lean|Lean backend|Extract.*Lean|Print.*Lean|emit.*Lean|ToLean" src

# 3) run on your tiny async crate and paste the FIRST error
charon cargo --preset=aeneas
./bin/aeneas -backend lean yourcrate.llbc -split-files
```

(That last error message is gold: it usually names the unsupported LLBC node / pass that fails.)

---

## 4) What “starting work” usually means in Aeneas terms

Once you have the async failure:

### If it fails **in Charon**:

You’re adding async/coroutine lowering into LLBC export (or enabling it). Then Aeneas can’t proceed until the IR exists.

### If it fails **in Aeneas translation**:

You’ll implement translation support for the new LLBC constructs, *then* decide what the Lean backend should output (state-machine `Poll` model vs deeper concurrency model).

### If it “works” but Lean proofs break:

Then you’re modifying the Lean backend stdlib/tactics (`progress` etc.) to handle the new generated shape (e.g. extra `match Poll` branches).

---

## 5) Quick sanity goal for the very first PR

Aim for something small and undeniable:

> “Aeneas Lean backend can translate an `async fn` that has no real concurrency (no shared state), producing a `poll`-style state machine and compiling in Lean.”

That’s a great Phase-1 milestone before bringing in Iris/CSL.

---

If you paste the outputs from step (3)—especially the `rg` results + the first async failure—I can point you to the exact OCaml modules to edit and what the minimal change should look like.

[1]: https://github.com/AeneasVerif/aeneas "GitHub - AeneasVerif/aeneas: A verification toolchain for Rust programs"
