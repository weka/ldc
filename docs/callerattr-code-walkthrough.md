# `callerAttr` / `@CTX_SWITCH` — Code Walkthrough

A guided explanation of the caller-required-attribute implementation on the
`callerattr-option-a` branch. Built for understanding and reviewing the code.

Covers the three implementation commits:

- `9f8aacdfa8` Add Option A caller-required attributes (`@CTX_SWITCH` via `.ATTR` marker)
- `e29e51e529` Switch caller-attr marker to postfix `callee(args) @CTX_SWITCH` syntax
- `0c423f1bdc` caller-attr: foreach/opApply support + participate in name mangling

Scope: ~1,300 lines across the DMD/LDC frontend (`dmd/`) plus the druntime
definitions. Two design docs already live alongside this one
(`ctx-switch-marking-spec.md`, `ctx-switch-option-a-implementation-spec.md`);
**note the implementation spec is stale** on the call-site syntax — see §4.

---

## 1. The mental model

There are two halves to the feature:

1. **A declaration side** — a function *carries* an attribute, written
   `@CTX_SWITCH` (which is just a UDA, `callerAttr!"CTX_SWITCH"`).
2. **A call side** — every call to such a function must *acknowledge* it with a
   postfix marker, `callee(args) @CTX_SWITCH`, and the enclosing function must
   itself carry the attribute (so it propagates up the call tree).

The entire enforcement is **layered on top of existing UDA machinery**. There is
no new type-system concept, no new `STC` bit (the spec considered one but it
wasn't needed), no change to `TypeFunction`. A `callerAttr!"X"` value is an
ordinary UDA that the compiler learns to *recognize* and *enforce*. That's the
key design choice — it's why the diff is only ~1,300 lines and reuses
`foreachUda`, `checkFunctionAttributes`, the normal call path, etc.

The work splits across the compiler pipeline exactly where you'd expect:

| Stage          | File                | Job                                                          |
|----------------|---------------------|--------------------------------------------------------------|
| Library        | `core/attribute.d`  | define `callerAttr` / `callerAttrFake`                       |
| Recognition    | `id.d`, `attrib.d`  | "is this UDA a caller-attr? what's its name?"                |
| Parse          | `parse.d`, `expression.d` | capture the `@X` marker on a call                      |
| Semantic       | `expressionsem.d`   | enforcement (E1/E2/E3 + lambda inference + arg check + tie-break) |
| Overload res.  | `funcsem.d`         | tie-break dual overloads                                     |
| Lowering       | `statementsem.d`    | `foreach` → `opApply` auto-marking                           |
| Mangling       | `dmangle.d`         | disambiguate colliding dual overloads                        |

---

## 2. The library side (`runtime/druntime/src/core/attribute.d`)

```d
struct callerAttr(string name_, bool fake_ = false) {
    enum string name = name_;
    enum bool   fake = fake_;
}
template callerAttrFake(string name_) { alias callerAttrFake = callerAttr!(name_, true); }
```

That's the whole runtime contribution. `callerAttr!"CTX_SWITCH"` is a **struct
template instance** — its identity is `(name, fake)` carried as *template value
arguments*. This matters: the compiler reads the name straight out of
`TemplateInstance.tdtypes` without ever CTFE-evaluating anything (the lower-risk
"Q1a / type-per-name" path from the spec). `callerAttrFake` is just the same
struct with `fake = true`.

Use-site:

```d
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";
```

---

## 3. Recognition (`dmd/id.d` + `dmd/attrib.d`)

`id.d` registers one interned identifier: `udaCallerAttr → "callerAttr"`.

`attrib.d` adds the two recognizers everything else calls:

- **`isCallerAttrStruct(sd, out name, out fake)`** — given a struct declaration,
  walk to its parent `TemplateInstance`, confirm its `tempdecl` is the
  `callerAttr` template *in `core.attribute`* (`isCoreUda(ti.tempdecl,
  Id.udaCallerAttr)` — the same trick used for `@mustuse` etc.), then read
  `tdtypes[0]` (the `StringExp` name) and `tdtypes[1]` (the `fake` bool). No
  CTFE.
- **`isCallerAttrExp(e, ...)`** — the same, but starting from a UDA *expression*
  that is a `TypeExp` of that struct.

So "does this function carry `@CTX_SWITCH`?" reduces to: scan its UDAs with
`foreachUda`, run `isCallerAttrExp` on each, match on name+fake.

---

## 4. Parsing the marker (`dmd/parse.d` + `dmd/expression.d`)

The marker syntax `callee(args) @CTX_SWITCH` is new grammar — a postfix
`@Identifier` on an expression. In the postfix-expression loop in `parse.d`:

```d
case TOK.at:
    if (peekNext() == TOK.identifier) {
        nextToken();                 // skip '@'
        Identifier id = token.ident;
        nextToken();                 // skip marker name
        auto ce = e.isCallExp();
        if (!ce) {                   // no-parens form: `tick @CTX_SWITCH`
            ce = new AST.CallExp(loc, e);  // becomes a zero-arg call
            e = ce;
        }
        ce.markedCallerAttr = id;
        continue;
    }
    return e;
```

Two things to notice:

- The marker stored (`markedCallerAttr`) is the **raw identifier token**
  (`CTX_SWITCH`), *not yet resolved* to an attribute. Resolution happens in
  semantic, in the correct scope.
- The **no-parens form** (`tick @CTX_SWITCH;`) is desugared right here into a
  zero-arg `CallExp`. So everything downstream only ever deals with a `CallExp`.

`expression.d` adds two fields to `CallExp`:

- `Identifier markedCallerAttr` — the marker (null if none).
- `bool callerAttrAutoMarked` — "this is a compiler-generated call, treat it as
  implicitly marked" (used by `foreach`, see §7).

And critically, `syntaxCopy()` now **copies `markedCallerAttr`**. Without this,
any call inside a template body loses its marker on instantiation and spuriously
errors "call must be marked." This is exactly the kind of bug that the
postfix-at-parse-time design introduces, and the copy fixes it.

> **The implementation spec is stale here.** It describes a `.ATTR`
> member-access syntax (`callee.CTX_SWITCH(args)`) that had to be *intercepted*
> inside `resolveUFCS` before UFCS rewriting — fragile. The shipped code uses the
> postfix-`@` syntax and captures the marker structurally at parse time, so there
> is **no `resolveUFCS` interception at all** anymore. Trust the code over that
> doc.

---

## 5. The core enforcement (`dmd/expressionsem.d`)

Everything funnels through one function, `checkCallerAttr(CallExp ce, Scope* sc,
Dsymbol callee)`, run **per call**. `callee` is whatever symbol carries the UDA:
a `FuncDeclaration` for a direct call, or the delegate/function-pointer
`VarDeclaration` for an indirect call.

It's wired into `visit(CallExp)` at **three** sites, matching the three kinds of
call:

1. Direct calls → via `checkFunctionAttributes(exp, sc, f)` (sits right next to
   the existing `checkNogc`/`checkSafety` calls — same pattern).
2. The DotVar method-call branch → explicit `checkCallerAttr(exp, sc, exp.f)`
   next to `checkNogc`.
3. Indirect calls (`!exp.f`) → `checkCallerAttr(exp, sc,
   callerAttrCalleeVar(exp.e1))`, where `callerAttrCalleeVar` digs the
   `VarDeclaration` out of a `VarExp`/`DotVarExp` so the attr on a `@CTX_SWITCH
   void delegate()` *parameter* is enforced.

### The three diagnostics

Inside `checkCallerAttr` (pseudocode):

```
resolve the written marker (if any) to its real attribute name
    → else error "@X is not a caller-required attribute (declare it with callerAttr)"
for each caller-attr UDA the callee carries:
    if it's the marked one → markerMatched = true
    if fake → skip entirely (no marker needed, no propagation)   ← the migration shim
    E2: not marked (and not auto-marked) → "call to `@X` function `foo` must be marked `foo() @X`"
    E1: enclosing sc.func doesn't carry X (real or fake):
          if sc.func is a lambda → INFER X (record it) instead of erroring
          else → "non-`@X` <kind> `f` cannot call `@X` function `g`"
E3: marker was written but callee carries no such attr
    → "`foo` is not a `@X` function; remove the `@X` marker"
```

Helper functions involved:

- **`callerAttrMarkerName(sc, loc, ident, ...)`** — resolves the raw marker
  identifier in scope, through its alias, to a struct type, then
  `isCallerAttrStruct` → the real attribute name + fake flag.
- **`symCarriesCallerAttr(sym, sc, wantName, wantFake)`** — scans a symbol's
  UDAs via `foreachUda` to see if it carries the attr with matching name+fake.
- **`callerAttrCalleeVar(e1)`** — for indirect calls, gets the `VarDeclaration`
  behind the callee (`VarExp` or `DotVarExp`) — the delegate/fn-ptr variable
  that carries the attr UDA on its declaration.

### Details that are easy to miss

- **`markerMatched` is per-call.** Only one `@X` marker can be written per call
  site, so if a callee carried *two* real caller-attrs, the second would fire
  E2. That's an inherent "one marker per call" limitation, by design.
- **Lambda inference is the escape from "annotate everything."** A lambda can't
  be hand-annotated `@CTX_SWITCH`, so when its body makes a marked call, the
  compiler *infers* the attribute onto the lambda — exactly like `@nogc`/`@safe`
  inference. This is what makes the delegate examples in the Notion spec work.

### Inference is stored in side tables, not on `FuncDeclaration`

```d
private __gshared const(char)[][][void*] inferredCallerAttrsByFunc;  // lambda -> [attr names]
private __gshared Loc[void*]              inferredCallerAttrLocByFunc; // lambda -> first ctx-switch loc
```

These are global associative arrays keyed by the *pointer* to the
`FuncDeclaration`. The comment is explicit about why: to **avoid adding a field
to `FuncDeclaration`**, which is mirrored in C++ (the DMD/LDC frontend is shared
C++/D, so adding a field is a cross-language change). The `Loc` table exists only
to make a `foreach` error point at the real `... @CTX_SWITCH` call inside the
loop body rather than at the generated `opApply` call. (See §9 — this is the part
I'd review hardest.)

### The value-side check (`checkCallerAttrArgs`)

Run after `functionParameters`. It enforces the lambda rule from the Notion
spec: a context-switching callable (an arg that carries or infers `@CTX_SWITCH`)
may only be passed to a parameter that *also* carries it — otherwise "cannot pass
`@CTX_SWITCH` lambda to non-`@CTX_SWITCH` parameter `dg`". `argCallable()`
extracts the callable behind an arg (`FuncExp`/`DelegateExp`/`&fn`/var), and
`paramCarriesCallerAttr()` reads the UDA off the *parameter declaration*.

> Note this is enforced on the **parameter's UDA**, not the delegate *type* —
> passing a plain function to a `@CTX_SWITCH` parameter is *not* caught (a known
> limitation; would need `TypeFunction` work).

---

## 6. Dual overloads & the tie-breaker (`dmd/funcsem.d` + `dmd/expressionsem.d`)

This is the `foreach` enabler. A container exposes **two `opApply` overloads** —
plain and `@CTX_SWITCH` — with *identical types* (the attribute is a UDA,
invisible to the type system). Normal overload resolution sees them as equally
good → ambiguous.

`funcsem.d` `resolveFuncCall`, **only when resolution is already ambiguous**
(`m.count > 1 && m.lastf && m.nextf`), calls
`disambiguateCallerAttrOverload(f1, f2, fargs, sc)`. That function counts, for
each candidate, how many caller-attr mismatches exist between each callable
argument and the matching parameter (arg carries X but param doesn't, or
vice-versa), and picks the lower-mismatch overload. A context-switching `foreach`
body → selects the `@CTX_SWITCH` `opApply`; a plain body → the plain one. It
returns null (no interference) whenever caller-attrs aren't involved (`relevant`
stays false) or on a tie, so ordinary ambiguities are untouched and surface as
the normal ambiguity error.

---

## 7. `foreach` auto-marking (`dmd/statementsem.d`)

When a `foreach` lowers to `aggr.opApply(body)`, *there is no source call site*
for the user to write a marker on. So `applyOpApply` sets:

```d
applyCall.callerAttrAutoMarked = true;
```

This flag means: in `checkCallerAttr`, **skip E2** (don't demand a written
marker — there's nowhere to write it) but **still run E1** (the enclosing
function must carry `@CTX_SWITCH`). Combined with §6 selecting the `@CTX_SWITCH`
`opApply` when the body context-switches, this gives the "foreach auto-carries
the attribute to the enclosing function" semantics from the Notion spec. And the
special-cased error wording uses the `Loc` side table to point at the real yield
inside the body ("non-`@X` function `f` context-switches here (via `foreach`
over `@X` function `g`)").

---

## 8. Mangling (`dmd/dmangle.d`)

This is the most delicate piece, and the long comment is worth reading in full.
The problem: the dual `opApply` overloads differ *only* by a UDA → they **mangle
to the same symbol** → codegen silently drops one ("skipping definition … same
mangled name"). So we must inject a discriminator.

`mangleCallerAttrDisc(sym, buf)` appends `Y` + (`R` real / `F` fake) + length +
name **for each caller-attr** — but **only if** the function both:

(a) carries a caller-attr, AND
(b) **has a same-name, same-type overload sibling**.

The collision gate (b) is the crucial correctness condition:

- A *standalone* `@CTX_SWITCH` function (`yield`, `send`, …) keeps its
  **baseline mangle**, so its definition and every cross-module call site agree.
  If the discriminator were applied unconditionally, whether it got emitted would
  depend on *whether the UDA happened to be semantically resolved* when the
  symbol was first mangled and cached — inconsistent across separately-compiled
  modules → `undefined symbol` link errors.
- The dual `opApply`s are co-resolved members of the same struct template, so
  they collide consistently everywhere → safe to discriminate.

To find siblings it enumerates the **whole overload set from its head** (looks
the ident up in the parent's symtab) because `overnext` is singly-linked and the
`@CTX_SWITCH` overload is usually declared *after* the plain one.

This is intentionally the *minimum* mangling impact — caller-attrs deliberately
do **not** otherwise affect mangling, so converted code links against
unconverted libraries.

---

## 9. Things to scrutinize in review

Not necessarily bugs, but where a critical eye pays off:

1. **The `__gshared` side tables.** Global mutable state keyed by `void*`
   `FuncDeclaration` pointers, never cleared. Two concerns: (a) in a
   long-lived/server compiler or across multiple `semantic` passes, stale entries
   persist and pointer identity is the only key; (b) **ordering dependence** —
   `checkCallerAttrArgs` and `disambiguateCallerAttrOverload` *read* the
   inferred-attr table, so they only work if the lambda's body was semantically
   analyzed (and inferred) *first*. For an inline lambda passed directly to a
   call that's usually true, but it's the fragile assumption. Worth a test where
   the lambda is defined/analyzed after the call point, or used in a template.

2. **Mangling timing.** The comment argues the collision gate makes the result
   resolution-timing-independent. Verify that hard with an actual
   separate-compilation test: define the dual-`opApply` container in one module,
   `foreach` over it in another, compile separately, link. That's the scenario
   the gating is designed for and the one most likely to surface a latent
   `undefined symbol`.

3. **Double-checking call sites.** `checkCallerAttr` is invoked from three
   branches. Confirm they're mutually exclusive (direct vs. DotVar method vs.
   indirect) so no call can produce duplicate E1/E2 diagnostics.

4. **The mismatch heuristic in the tie-breaker** counts mismatches symmetrically
   and picks the lower. Check behavior when *both* overloads carry caller-attrs,
   or with multiple callable args, to ensure it can't pick wrong silently (it
   returns null on a tie, which then surfaces as the normal ambiguity error —
   probably the safe fallback).

5. **Stale doc.** `ctx-switch-option-a-implementation-spec.md` still describes the
   `.ATTR` member-access syntax and `resolveUFCS` interception, which the code no
   longer uses. If that doc is meant to track reality, update it to the
   postfix-`@` design.

---

## 10. End-to-end trace: a yielding `foreach`

To tie it together, here's the path for:

```d
@CTX_SWITCH void scan(ref RobinHashTable!(K,V) t) {
    foreach (k, ref v; t) {
        yield() @CTX_SWITCH;   // OK
    }
}
```

1. **Parse** (`parse.d`): `yield() @CTX_SWITCH` → `CallExp` with
   `markedCallerAttr = CTX_SWITCH`. The `foreach` is an ordinary
   `ForeachStatement`.
2. **Lowering** (`statementsem.d`): the loop body becomes a delegate literal
   `flde`; the loop lowers to `t.opApply(flde)`, a `CallExp` flagged
   `callerAttrAutoMarked = true`.
3. **Semantic of the body**: `yield() @CTX_SWITCH` hits `checkCallerAttr` — the
   marker matches `yield`'s real attr (E2 satisfied), and the enclosing `sc.func`
   is the body *lambda* `flde`, which doesn't carry `@CTX_SWITCH`, so E1 *infers*
   it: `inferredCallerAttrsByFunc[flde] = ["CTX_SWITCH"]` (and records the loc).
4. **Overload resolution** of `t.opApply(flde)` (`funcsem.d`): plain vs.
   `@CTX_SWITCH` `opApply` tie → `disambiguateCallerAttrOverload` sees `flde`
   infers `CTX_SWITCH`, prefers the `@CTX_SWITCH` overload.
5. **`checkCallerAttr` on the `opApply` call**: callee carries `@CTX_SWITCH`;
   `callerAttrAutoMarked` skips E2; E1 checks the *enclosing* `scan` — which *is*
   `@CTX_SWITCH`, so it passes. (Had `scan` not been `@CTX_SWITCH`, E1 fires with
   the "context-switches here (via foreach …)" wording, pointing at the recorded
   `yield()` loc.)
6. **Mangling** (`dmangle.d`): the two `opApply` overloads collide → each gets a
   `Y`-discriminator so codegen keeps both.
