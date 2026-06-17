# Implementation Spec: Caller-Required Attributes with the `() @ATTR` Call-Site Marker

**Status:** ✅ Implemented & verified in this tree (Weka-local fork). See [Implementation status](#implementation-status).
**Implements:** the generalized `callerAttr` facility from [`ctx-switch-marking-spec.md`](./ctx-switch-marking-spec.md).
**Target:** Weka-local fork of the LDC/DMD frontend (`dmd/`). No upstreaming constraint.

> **Call-site syntax (updated):** the marker is now a **postfix attribute on the call**, `callee(args) @CTX_SWITCH`, rather than the earlier member-access form `callee.CTX_SWITCH(args)`. This required a parser change (new expression grammar: `PostfixExpression '@' Identifier`). **Tooling tradeoff:** unlike the member-access form (which parsed with existing grammars), this `@`-postfix syntax is *intrusive* to third-party D parsers (libdparse/DCD/serve-d/dfmt/etc.) until they are taught the grammar — i.e. it has the same ecosystem cost as design-spec Option B/D2. Everything below that refers to "the `.ATTR` marker" now means the `() @ATTR` postfix marker.

All file:line references below were verified against the current tree.

---

## Decisions (resolved)

The open questions were resolved as follows and the implementation follows these:

1. **`callerAttr` identity / recognition:** **(a) type-per-name.** `callerAttr!"X"` is a struct *template instance*; identity is read from the template's string value argument — no CTFE of values. Recognized via `isCallerAttrStruct` (parent `TemplateInstance` whose `tempdecl` is the `callerAttr` template in `core.attribute`).
2. **Propagation:** **explicit-only (v1).** A function that performs a marked call must itself be declared `@CTX_SWITCH` (or `@CTX_SWITCH_FAKE`); inference via `STC.inference` is deferred to a phase 2.
3. **Collision rule:** the marker fires when the trailing identifier resolves, in the calling scope, to a visible `callerAttr` alias; the alias must be visible in scope. (The "no real member of that name" refinement is left for phase 2; v1 treats a visible `callerAttr` alias as a marker.)
4. **"Fake" semantics:** **strict-fake.** A `@..._FAKE` function does not propagate the requirement to its callers and callers need no marker, but internal calls inside it still require their markers.
5. **Call-site scope:** v1 covers **direct calls to named functions, aggregate methods (incl. virtual / `opCall`), and indirect calls through `@CTX_SWITCH` delegate / function-pointer variables** (`scope` and non-`scope` alike). The attribute on a delegate/function-pointer parameter is carried by the parameter's declaration UDA, so it is enforced at the indirect call site. (Not yet: caller-attrs encoded in the delegate *type* itself — so passing a non-CS function to a `@CTX_SWITCH` delegate parameter is not value-side checked; that needs the `TypeFunction` work.)

---

## 1. Approach in one paragraph

`callerAttr!"NAME"` (in druntime) produces a compiler-recognized UDA. A function "carries" attribute `NAME` if its UDA list contains such a value (or, phase 2, if inferred). The call-site marker `callee.NAME(args)` is **ordinary member-access grammar** — no parser change. During expression semantics we intercept the `DotIdExp` `callee.NAME` *before* normal member/UFCS resolution: if `NAME` resolves to a `callerAttr` alias, we rewrite the expression to the plain call `callee(args)` tagged with the required attribute `NAME`, verify the callee actually carries `NAME` ("marker matches reality"), and run a `@nogc`-style caller-must-carry check to enforce upward propagation. Everything reuses existing machinery (`foreachUda`, `checkFunctionAttributes`, the `DotIdExp`/UFCS path); the only genuinely new logic is the marker interception and the per-function "required caller-attr set".

---

## 2. Data model

Because the facility is **generalized** (many named attributes: `CTX_SWITCH`, `HOLDS_LOCK`, …), a single `STC` bit cannot represent membership — a bit can't say *which* attribute. So:

- **Membership (declaration-side):** read from the function's existing UDA list via `foreachUdaNoSemantic`/`foreachUda` (`dmd/attrib.d:1267`,`:1307`). No new storage needed for explicitly-declared attributes.
- **Inferred set (phase 2):** a new field on `FuncDeclaration`, e.g. `Identifier[] inferredCallerAttrs;` (placed near the violation fields, `dmd/func.d:336`). Empty in explicit-only v1.
- **Fast-path flag (optional):** one free `STC` bit — `STC` is `enum STC : ulong` with the highest current bit at `STC.volatile_ = 0x40_0000_0000_0000` (`dmd/astenums.d:112`); bits 55–63 are free. A `STC.hasCallerAttr = 0x80_0000_0000_0000` flag lets hot call paths skip the UDA scan when a function carries none. Optional optimization, not required for correctness.
- **Call-site tag:** a new field on `CallExp` (`dmd/expression.d`, near `ignoreAttributes` at `:3553`), e.g. `Identifier markedCallerAttr;` — set when the call was written with a `.NAME` marker; `null` otherwise. Used to enforce "marker must match reality".

---

## 3. Recognizing `callerAttr` UDAs (identity)

Existing special UDAs are matched by **Identifier + being in `core.attribute`** via `isCoreUda` (`dmd/attrib.d:1246`) / `isEnumAttribute` (`dmd/attrib.d:1325`); `@mustuse` is the template (`dmd/mustuse.d` `isMustUseAttribute`). Those match a *fixed* symbol name — they cannot carry a per-attribute string.

For the generalized facility we recognize the **`callerAttr` template itself** (by symbol identity in a designated module — propose `core.attribute` or `ldc.attributes`), then extract the name:

- **Recommended (Q1a):** `callerAttr!"X"` yields a value whose **type is a template instance** `CallerAttr!("X")` of a template declared in the designated module. Recognition: the UDA expression's type is an instantiation of that template; the name is the instance's first template value argument (a `StringExp`). No value CTFE required — read the `TemplateInstance.tiargs`.
- **Alternative (Q1b):** one struct type `CallerAttr { string name; bool fake; }`; recognize by type symbol+module, then CTFE the UDA expression to a struct literal and read `.name`/`.fake`.

A helper mirroring `isCoreUda` does the matching:

```
// dmd/attrib.d (new)
bool isCallerAttr(Expression uda, out Identifier name, out bool fake);
```

`callerAttrFake!"X"` is the same template/type with `fake = true`.

---

## 4. druntime side (the only library code)

Proposed (designated module so the frontend can match by symbol). Exact shape depends on Q1; this is the type-per-name form:

```d
// runtime/druntime/src/core/attribute.d  (or ldc/attributes.d)

struct CallerAttr(string attrName, bool isFake) {
    enum name = attrName;
    enum fake = isFake;
}

// Factory aliases used at the use-site:
template callerAttr(string name)     { enum callerAttr     = CallerAttr!(name, false)(); }
template callerAttrFake(string name) { enum callerAttrFake = CallerAttr!(name, true )(); }
```

Use-site:

```d
import core.attribute : callerAttr, callerAttrFake;

alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";
```

> The frontend recognizes the `CallerAttr` template by name + module (extend `isCoreUda`). The `Yes.requireAtCallSites` parameter from the design sketch is implicit in v1 (always required); it can become a real template parameter later if a non-call-site-required attribute is ever wanted.

---

## 5. Frontend changes, by phase

### Phase 0 — recognition plumbing
- Add `Id.callerAttr` / `Id.callerAttrFake` to `dmd/id.d` and the `CallerAttr` recognition to `dmd/attrib.d` (`isCallerAttr`, alongside `isCoreUda` `:1246`).
- Add `markedCallerAttr` to `CallExp` (`dmd/expression.d:3553` neighborhood) and (optional) `STC.hasCallerAttr` (`dmd/astenums.d:112`).
- Helper `funcCarriesCallerAttr(FuncDeclaration f, Identifier name)`: scan `f`'s UDAs via `foreachUdaNoSemantic` (`dmd/attrib.d:1307`) + (phase 2) `inferredCallerAttrs`.

### Phase 1 — call-site marker interception (the core)
The marker `callee.NAME(args)` reaches semantics through the `DotIdExp` path. Intercept in **`resolveUFCS`** (`dmd/expressionsem.d:1087`), which already special-cases a `DotIdExp` callee and calls `die.dotIdSemanticPropX()` (`:1097`) before the UFCS search (`:1193`):

1. After `dotIdSemanticPropX` returns and before UFCS lookup, test `isCallerAttrMarker(die.ident, sc)` — does `die.ident` resolve in `sc` to a visible `callerAttr` alias, with **no** real member of that name on `typeof(die.e1)` (collision rule, Q6c)?
2. If yes: set `callExp.markedCallerAttr = name`, replace the callee with `die.e1` (the bare callee), and let normal call resolution proceed on `die.e1(args)`.
3. The no-parens form `foo.NAME;` arrives as a `DotIdExp` not wrapped in a `CallExp`; handle in `visit(DotIdExp)` (`dmd/expressionsem.d:8110`) / `dotIdSemanticProp` (`:14375`): rewrite to a marked zero-arg call `foo()`.

Member-lookup error path to suppress when it's actually a marker: `dotIdSemanticPropX` emits "expression `%s` does not have property `%s`" at `dmd/expressionsem.d:14349-14352` — the interception must run before that fires.

### Phase 2 — enforcement (marker ↔ reality, and propagation)
Add `checkCallerAttr(CallExp ce, Scope* sc, FuncDeclaration callee)` and call it from `checkFunctionAttributes` (`dmd/expressionsem.d:16279`), which already runs per call in `visit(CallExp)` (`:6625`), gated by `ignoreAttributes` (`:6340`). Logic, for each attribute `NAME` the callee carries, plus the call's `markedCallerAttr`:

- **Callee carries `NAME`, call NOT marked** → error E2 ("must be marked `foo.NAME(...)`").
- **Call marked `NAME`, callee does NOT carry `NAME`** (and isn't fake-`NAME`) → error E3 ("`foo` is not a `@NAME` function").
- **Callee carries `NAME` (non-fake), enclosing `sc.func` does NOT carry `NAME`**:
  - explicit-only (v1): error E1 ("non-`@NAME` … cannot call `@NAME` …"), modeled on the `@nogc` message at `dmd/expressionsem.d:2204`.
  - inferred (phase 2): record a violation and add `NAME` to `sc.func.inferredCallerAttrs`, mirroring `setGCCall`/`setGC` (`dmd/func.d:1311`,`:1291`) and the `STC.inference` flow in `semantic3` (`dmd/semantic3.d:282`).
- **Callee is fake-`NAME`** (`callerAttrFake`): do **not** require `sc.func` to carry `NAME`, and do **not** require the caller to mark the call (the fake function is a migration boundary). Inside a fake function, internal marker requirement follows Q4 (strict default).

### Phase 3 (deferred) — indirect calls, delegates, types
Make the attribute part of `TypeFunction` (`dmd/mtype.d:3047`) so `@CTX_SWITCH void delegate()` enforces at indirect call sites; handle virtual dispatch, `opCall`, function pointers, `alias`. Mangling impact (and thus separate-compilation/migration) is decided with design-spec Q3 — **kept out of v1** so converted code links against unconverted libraries.

---

## 6. Diagnostics catalog

| ID | Condition | Message (proposed) |
|----|-----------|--------------------|
| E1 | non-`@NAME` function performs a `@NAME` call | `` `@NAME` function `g` cannot be called from non-`@NAME` function `h` `` (phrased like the `@nogc` error) |
| E2 | `@NAME` call written without the marker | `` call to `@NAME` function `foo` must be marked `foo.NAME(...)` `` |
| E3 | `.NAME` marker on a callee that doesn't carry `NAME` | `` `foo` is not a `@NAME` function; remove the `.NAME` marker `` |
| E4 | `.NAME` used but `NAME` alias not visible in scope | falls through to the normal "no property `NAME`" error (`:14351`) — by design (Q3) |

Emit via `error(loc, ...)` (top-level), e.g. as `dmd/expressionsem.d:2204`.

---

## 7. Test plan

Tests live under `tests/dmd/compilable/` (must compile) and `tests/dmd/fail_compilation/` (must fail), with expected errors in a `TEST_OUTPUT` block (format per `tests/dmd/fail_compilation/attributediagnostic_nogc.d`). A shared helper module declares the attribute. Line numbers in the `TEST_OUTPUT` blocks below are **illustrative** — they get finalized once the code is laid out.

### Shared helper (used by all tests)

```d
// tests/dmd/compilable/imports/callerattr_defs.d  (and a copy path for fail tests)
module callerattr_defs;
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";
```

### 7.1 Should compile cleanly — `tests/dmd/compilable/callerattr_ok.d`

```d
// EXPECTED: compiles with no errors
import callerattr_defs;

@CTX_SWITCH void yieldNow() {}          // a CS-capable leaf
void plain() {}                          // not CS-capable

// Propagation: a CS function may call CS functions when marked.
@CTX_SWITCH void worker() {
    yieldNow.CTX_SWITCH();              // OK: marker matches, worker is @CTX_SWITCH
    plain();                            // OK: plain() is not CS, no marker needed
}

// The single root (fiber main) starts the tree.
@CTX_SWITCH void fiberMain() {
    worker.CTX_SWITCH();               // OK
}

// Forwarder via the FAKE escape hatch: withFunc is NOT forced onto its callers.
@CTX_SWITCH_FAKE void withLock(void delegate() dg) {
    yieldNow.CTX_SWITCH();             // (strict-fake) internal CS call still marked
    dg();
}

void notYetMigrated() {
    withLock(() {});                   // OK: calling a FAKE function needs no marker
                                        //     and does not force notYetMigrated to be @CTX_SWITCH
}
```

### 7.2 Should compile cleanly — no-parens property form — `tests/dmd/compilable/callerattr_ok_noparens.d`

```d
// EXPECTED: compiles with no errors
import callerattr_defs;

@CTX_SWITCH void tick() {}

@CTX_SWITCH void run() {
    tick.CTX_SWITCH;                   // OK: marked zero-arg call, equivalent to tick.CTX_SWITCH()
}
```

### 7.3 Should FAIL — unmarked CS call (E2) — `tests/dmd/fail_compilation/callerattr_unmarked.d`

```d
/*
TEST_OUTPUT:
---
fail_compilation/callerattr_unmarked.d(11): Error: call to `@CTX_SWITCH` function `yieldNow` must be marked `yieldNow.CTX_SWITCH(...)`
---
*/
import callerattr_defs;

@CTX_SWITCH void yieldNow() {}

@CTX_SWITCH void worker() {
    yieldNow();                        // ERROR E2: missing the .CTX_SWITCH marker
}
```

### 7.4 Should FAIL — non-CS caller calls CS callee (E1) — `tests/dmd/fail_compilation/callerattr_propagation.d`

```d
/*
TEST_OUTPUT:
---
fail_compilation/callerattr_propagation.d(11): Error: `@CTX_SWITCH` function `yieldNow` cannot be called from non-`@CTX_SWITCH` function `oops`
---
*/
import callerattr_defs;

@CTX_SWITCH void yieldNow() {}

void oops() {                          // not @CTX_SWITCH
    yieldNow.CTX_SWITCH();             // ERROR E1: oops must itself be @CTX_SWITCH
}
```

### 7.5 Should FAIL — marker on a non-CS function (E3) — `tests/dmd/fail_compilation/callerattr_bogus_marker.d`

```d
/*
TEST_OUTPUT:
---
fail_compilation/callerattr_bogus_marker.d(11): Error: `plain` is not a `@CTX_SWITCH` function; remove the `.CTX_SWITCH` marker
---
*/
import callerattr_defs;

void plain() {}

@CTX_SWITCH void caller() {
    plain.CTX_SWITCH();                // ERROR E3: plain() does not carry CTX_SWITCH
}
```

### 7.6 Should FAIL — collision falls back to member lookup (E4, Q6c) — `tests/dmd/fail_compilation/callerattr_collision.d`

```d
/*
TEST_OUTPUT:
---
fail_compilation/callerattr_collision.d(13): Error: no property `CTX_SWITCH` for `s` of type `S`
---
*/
import callerattr_defs;

struct S { void run() {} }             // S has no member CTX_SWITCH

void f() {
    S s;
    s.CTX_SWITCH();                    // Per Q6c: `s` is not callable as a CS marker target,
                                        // and S has no member CTX_SWITCH -> normal member error
}
```

> 7.6 documents the chosen collision behavior; if Q6 selects rule (a) or (b) the expected output changes accordingly.

---

## 8. Risks & open implementation issues

- **Interception ordering vs. UFCS.** The marker check must run before UFCS turns `callee.NAME` into `NAME(callee)`. `resolveUFCS` (`:1087`) is the right chokepoint, but the no-parens `DotIdExp` path (`:8110`) is separate and must be handled too — easy to miss one and get inconsistent behavior.
- **CTFE vs. template-arg extraction for the name.** Q1a (type-per-name) avoids CTFE and is the lower-risk path; Q1b needs reliable CTFE of the UDA at the point of checking.
- **Inference complexity (phase 2).** Wiring a new inferred attribute into the `STC.inference`/`semantic3` machinery is the hardest part; explicit-only v1 sidesteps it (Q2).
- **`__traits` / reflection.** Expose "carries caller-attr X" so tooling/tests can introspect; low effort, do alongside phase 0.
- **Error-message line stability.** `TEST_OUTPUT` blocks are line-sensitive; finalize messages early to avoid churning the test files.

---

## 9. Suggested landing order

1. Phase 0 + Phase 1 + Phase 2 (explicit-only), with tests 7.1, 7.3–7.6 → a usable, enforced feature for direct calls.
2. Add 7.2 (no-parens) and `__traits` support.
3. Phase 2 inference (if Q2 wants it) + the fake/strict tests.
4. Phase 3 (delegates/types/virtual) + mangling decision.

---

## Implementation status

Implemented and verified against the modified compiler (`build/bin/ldc2`, DMD 2.108.1 base). Phases 0–2 (explicit-only, direct calls + aggregate methods) are done.

### Files changed
- `runtime/druntime/src/core/attribute.d` — added the `callerAttr(string, bool=false)` struct template and the `callerAttrFake` alias.
- `dmd/id.d` — added `udaCallerAttr` → `"callerAttr"`.
- `dmd/attrib.d` — added `isCallerAttrStruct` / `isCallerAttrExp` recognition helpers (+ `dmd.dstruct`/`dmd.dtemplate` imports).
- `dmd/expression.d` — added `CallExp.markedCallerAttr` (the `.ATTR` marker recorded at a call site).
- `dmd/expressionsem.d` —
  - `resolveUFCS`: intercept `callee.ATTR(args)` and rewrite to a marked plain call;
  - `visit(DotIdExp)`: intercept the no-parens `callee.ATTR;` form;
  - `callerAttrMarkerName`, `symCarriesCallerAttr`, `callerAttrCalleeVar`, `checkCallerAttr` helpers (`checkCallerAttr` takes any UDA-carrying `Dsymbol` — a `FuncDeclaration` for direct calls or the delegate/function-pointer `VarDeclaration` for indirect calls);
  - wired `checkCallerAttr` into the `CallExp` path: `checkFunctionAttributes` for the VarExp/most branches, the DotVar method-call branch, and the `t1.ty != Tfunction` branch for delegate / function-pointer calls.

### Verified behavior
- `tests/dmd/compilable/callerattr.d` — compiles cleanly (propagation chain, fake forwarder, no-parens form, aggregate methods).
- `tests/dmd/fail_compilation/callerattr_unmarked.d` (E2):
  `` Error: call to `@CTX_SWITCH` function `…yieldNow` must be marked `yieldNow.CTX_SWITCH(...)` ``
- `tests/dmd/fail_compilation/callerattr_propagation.d` (E1):
  `` Error: non-`@CTX_SWITCH` function `…oops` cannot call `@CTX_SWITCH` function `…yieldNow` ``
- `tests/dmd/fail_compilation/callerattr_badmarker.d` (E3):
  `` Error: `…plain` is not a `@CTX_SWITCH` function; remove the `.CTX_SWITCH` marker ``

- `tests/dmd/fail_compilation/callerattr_delegate.d` — indirect (delegate / function-pointer) calls: unmarked `@CTX_SWITCH` delegate (E2, incl. `scope`), non-CS caller (E1), stray marker on a plain delegate (E3).

Each fail test's `TEST_OUTPUT` block matches the compiler's actual output (path + line + message). Regression: member-access/UFCS/template-heavy and delegate/range-heavy `core.*`/`std.*` modules — including `core.thread.fiber`, `std.algorithm.*`, `std.range`, `std.functional` — still compile unchanged (no false positives from the indirect-call check). `scope` and non-`scope` delegate parameters enforce identically.

### Known limitations (deferred)
- No inference (explicit annotation required on every non-root function on the chain); in particular a CS lambda can't yet be annotated, so lambdas can't make marked calls.
- Caller-attrs are not encoded in the delegate/function-pointer *type*, only on the parameter declaration. So the indirect *call* is enforced, but passing a non-CS callable into a `@CTX_SWITCH` delegate parameter is not value-side checked (needs `TypeFunction` work). Indirect calls through a delegate that isn't a simple variable/field (e.g. one returned from a call) aren't gated.
- Collision refinement (a real member sharing a `callerAttr` alias name) not handled — a visible alias always wins.
- Attribute does not affect mangling (intentional, so converted code links against unconverted libraries).
