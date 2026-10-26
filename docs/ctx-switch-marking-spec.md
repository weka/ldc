# Spec: Marking Context-Switching Functions in D

**Status:** Draft — options exploration
**Goal:** Provide a **general, reusable** language/compiler mechanism for *caller-required, call-site-visible* function attributes. Marking context-switching functions (yielding control from a Weka fiber — any operation that can suspend the current fiber) is the **first client / motivating use case**, not the whole feature. The core requirement: **at the call site it is visible whether the callee carries the attribute** (e.g. can context-switch).

> Terminology used below: a function that may context-switch is *CS-capable*. The property we want to track and surface is "this call may yield the fiber". `CTX_SWITCH` is used throughout as a concrete instance of a generic *caller-required attribute*.

---

## Design axes (what the options vary along)

- **Where the mark lives:** in the *type system* (a token type / parameter) vs. as a *function attribute* (UDA / storage class).
- **Call-site obligation:** none / signature-only-visible / mandatory per-call-site syntax.
- **Propagation:** none / inferred / explicit / hybrid.
- **Generality:** bespoke single attribute vs. general user-definable caller-required-attribute facility.
- **Implementation surface:** druntime-only, frontend-semantic-only, or frontend-semantic + new parser syntax.

The recommended options (**A**, then **B**) are presented first; the weaker alternatives (**C**, **D**, **E**) follow as rejected alternatives.

---

## The generalized facility (shared by Options A and B)

Options A and B are the **recommended** direction and the **same mechanism** — your `callerAttr` / `callerAttrFake` sketch, generalized — differing **only** in how the call-site marker is *spelled*. Instead of hard-coding "context switch," a library declares a *named caller-required attribute*; the compiler enforces (a) upward propagation and (b) the mandatory call-site marker for any function tagged with it. Context-switch is the first client.

```d
alias CTX_SWITCH      = callerAttr("CTX_SWITCH", Yes.requireAtCallSites);
alias CTX_SWITCH_FAKE = callerAttrFake("CTX_SWITCH", Yes.requireAtCallSites);
```

**`callerAttrFake`:** marks a function as *carrying* the attribute for forwarding/delegate-parameter purposes **without** making it a propagation source to its own callers.

Shared pros/cons of the generalized facility (independent of spelling):

| Pros | Cons |
|---|---|
| **One mechanism, many capabilities** — context-switch today, "holds-lock"/"blocking"/"realtime-unsafe" later, all with consistent semantics and tooling. | Must define how a *value/alias* (`callerAttr(...)`) becomes a compiler-enforced attribute — a genuinely new concept; today only fixed `isCoreUda` markers are special. |
| Parameter-level annotation (`@CTX_SWITCH void delegate() dg`) gives precise rules for delegates/forwarders — directly models the `withFunc` case that bespoke Option D handles only with extra rules. | Adds a registration/identity model for user-defined attributes (cross-module identity, templates, separate compilation — see Q3). |
| `requireAtCallSites` flag makes call-site obligation a per-attribute policy — flexible. | Highest maintenance; the most surface for subtle soundness bugs. |
| Clean separation: druntime declares attributes, frontend provides one generic enforcer. | Risk of over-engineering if context-switch turns out to be the only real client. |

The two options below inherit all of the above; the tables only list what the **spelling choice** adds or removes.

---

## Option A — Generalized `callerAttr` with `.ATTR` call-site marker (member-access) — RECOMMENDED

> **Tooling intrusiveness: near-NON-INTRUSIVE.** The marker is spelled as ordinary member access, which existing parsers already accept → files keep parsing everywhere; only minor semantic-resolution noise around the marker token. See [Tooling & ecosystem intrusiveness](#tooling--ecosystem-intrusiveness).

The call-site marker is spelled as a postfix dot: `callee.ATTR(args)` (your latest proposal). The compiler intercepts a `DotIdExp` whose trailing identifier resolves, in the enclosing scope, to a `callerAttr` alias, and reinterprets `LEFT.ATTR(args)` as "call `LEFT(args)`, marked `ATTR`" — so `ATTR` is **never** looked up as a real member of `LEFT`. Enforcement, propagation, and "fake" semantics are identical to Option B.

```d
alias CTX_SWITCH = callerAttr("CTX_SWITCH");

@CTX_SWITCH void g() {
    withFunc.CTX_SWITCH({ foo.CTX_SWITCH; });
    f.CTX_SWITCH(1, 2, 3);
}
```

**Why this is the lead option:** `callee.ATTR(args)` and `callee.ATTR` are **already valid D grammar**. Every third-party parser already accepts them, so the catastrophic failure mode of Option B (whole-module parse error → all features off) **does not occur** — and it's also less compiler work.

| Pros (vs. B) | Cons (vs. B) |
|---|---|
| **No grammar change at all.** libdparse, Visual D, IntelliJ-D, tree-sitter-d, dfmt, highlighters all keep parsing the file. The single biggest advantage over `@`. | The marker is **lexically indistinguishable from real member access / UFCS**. The compiler must reserve the alias identifier in dot-resolution; a real member or UFCS function of the same name collides (needs a resolution rule — Q6). |
| **Graceful degradation, not collapse:** DCD/serve-d still parse the file, so GoToDefinition/References keep working for *every other* symbol. Only the marker token itself may not resolve → at worst a "cannot resolve `CTX_SWITCH`" squiggle, not a dead file. | DCD may still try to *autocomplete* `.CTX_SWITCH` as a member and offer nothing/wrong; "find references" on a same-named real member could be muddied. **Semantic** tooling is mildly affected even though **parsing** is not. |
| Reuses the existing `DotIdExp` AST node; interception is a localized semantic hook, **no parser/AST changes** — strictly less compiler work than Option B. | Less visually distinctive than `@` — `.CTX_SWITCH` can read like an ordinary field/method to a human skimming. Still greppable, but weaker as a "this is special" signal. |
| Satisfies the **hard per-call-site visibility requirement** — the marker is right at the call. | Chaining/precedence needs a rule: in `a.b().CTX_SWITCH()`, the marker binds the immediately-preceding callable; `a.CTX_SWITCH.b()` is something else. Must be specified. |
| Clean and refactor-safe — uses **real grammar**, not a comment/pragma kludge. | The no-parens form `foo.CTX_SWITCH;` overlaps with property/UFCS call syntax; meaning ("marked call of `foo` with no args") must be defined and distinguished from a marked property access. |

**Implementation cost:** High — the generalized facility **plus** a `DotIdExp` interception rule and collision-resolution logic in member lookup, but **no parser/AST/grammar work**. Lower total compiler cost than Option B, and far lower ecosystem cost.

---

## Option B — Generalized `callerAttr` with `@ATTR` call-site marker

> **Tooling intrusiveness: INTRUSIVE.** New `@ATTR` expression syntax breaks the libdparse-based stack (DCD GoToDefinition/References, serve-d, dfmt, D-Scanner), Visual D, IntelliJ-D, and third-party highlighters until each is patched. See [Tooling & ecosystem intrusiveness](#tooling--ecosystem-intrusiveness).

Same mechanism as Option A, but the call-site marker is a postfix `@ATTR` between the callee and its arguments: `callee@ATTR(args)`. This is your examples 2/3 spelling.

```d
@CTX_SWITCH_FAKE void withFunc(@CTX_SWITCH void delegate() dg) { dg@CTX_SWITCH(); }
@CTX_SWITCH      void g() { f@CTX_SWITCH(1, 2, 3); }
```

| Pros (vs. A) | Cons (vs. A) |
|---|---|
| **Most visually distinctive** — `@CTX_SWITCH` cannot be mistaken for an ordinary field/method; strongest "this is special" signal. | **Intrusive: breaks the third-party tooling ecosystem** (whole-module parse failure → GoToDefinition/References/format/lint disabled on affected files) until every independent parser is patched. |
| No ambiguity with real members/UFCS — `@` is unambiguously the marker. | **New expression grammar** with no precedent: requires parser + AST + expression-semantic plumbing (`parsePostExp` has no `@` handling today). Highest compiler cost of any option. |
| | Hardest to maintain against upstream DMD frontend rebases (fork divergence in the parser). |

**Implementation cost:** Very High — the generalized facility **plus** net-new call-site grammar/AST.

---

## Option C — Type-token parameter (`ctxsw` value threaded through calls)

> **Tooling intrusiveness: NON-INTRUSIVE.** No grammar change; GoToDefinition/References and all editor tooling keep working. See [Tooling & ecosystem intrusiveness](#tooling--ecosystem-intrusiveness).

*Rejected alternative.* Your example 1. A magic, non-constructible token type (`struct ctxsw` with `@disable this()`) is passed as a parameter to every CS-capable function; callers must thread a `CTXSW` value through.

```d
void boom(ctxsw CTXSW) {}
auto f(ctxsw CTXSW) { return (ctxsw CTXSW) => boom(CTXSW); }
```

**How visibility works:** the capability is encoded in the *signature* (the function has a `ctxsw` parameter) and the token must be physically passed at the call. The token "infects" any function that wants to call a CS-capable function — it must itself receive one to have a value to pass.

| Pros | Cons |
|---|---|
| **Zero new language features** — pure library + existing UDAs. No fork risk, trivially upstream-neutral. | Call site reads as an ordinary argument (`boom(CTXSW)`), **not** a distinctive marker; visibility is weak unless you grep for the token. |
| Propagation is automatic and sound: you *cannot* call a CS-capable fn without already holding a token, which you only get by being CS-capable yourself. | Intrusive on every signature and every call; churns existing code heavily. Interacts awkwardly with delegates, overload sets, `opXXX`, UFCS, and existing APIs that can't take the extra param. |
| Works with templates/IFTI naturally (token is just a parameter). | Token must be materialized somewhere (`ctxsw CTXSW = void;`), and `@disable this()` + `void`-init is a hole that can be abused to forge a token. |
| Easy to prototype today; no compiler change strictly required. | Depends on `@nocapture` semantics that **do not exist yet** in this repo; without real capture-checking the token can be captured/escaped, weakening guarantees. Runtime cost unless the param is elided. |

**Implementation cost:** Low if accepted as "convention + library"; Medium if you want real escape/capture guarantees (`@nocapture` would have to be designed and implemented — it is absent today).

**Why rejected:** call-site visibility is too weak (a token argument is not a distinctive marker), and it depends on `@nocapture`, which does not exist.

---

## Option D — Bespoke function attribute **plus mandatory `@` call-site annotation** (`f@CTX_SWITCH(...)`)

> **Tooling intrusiveness: INTRUSIVE.** New `@ATTR` expression syntax breaks libdparse-based tooling (DCD GoToDefinition/References, serve-d, dfmt, D-Scanner), Visual D, IntelliJ-D, and third-party highlighters until each is patched. See [Tooling & ecosystem intrusiveness](#tooling--ecosystem-intrusiveness).

*Rejected alternative.* Your examples 2/3, specialized to context-switch. A built-in marker `@CTX_SWITCH` carried on the function declaration, **plus** the rule that **every call to a CS-capable function must be written with a call-site marker** `f@CTX_SWITCH(...)` (and `dg@CTX_SWITCH()` for delegates), or it is a compile error.

```d
@CTX_SWITCH void g() {
    withFunc@CTX_SWITCH({ foo@CTX_SWITCH; });
    f@CTX_SWITCH(1,2,3);
}
```

| Pros | Cons |
|---|---|
| **Best possible call-site visibility** — literally the strong per-call-site marker requirement; impossible to miss a yielding call. | **New expression syntax** with no precedent: `parsePostExp` (`parse.d:8938`) has no `@` handling, and `@` is currently only a declaration-level token. Requires grammar changes, new AST, and disambiguation against existing `@` uses. |
| Acts as executable documentation and as a diff-review signal (reviewers see new yield points appear). | Intrusive to the third-party tooling ecosystem (same blast radius as Option B). |
| Built-in caller-must-match enforcement (the `@nogc` direction) also forces the enclosing function to be marked. | Verbose; every call site changes. Tooling (formatters, IDEs, ddoc, `__traits`) must learn the new syntax. |

**Implementation cost:** High. Frontend semantic work (clone the `@nogc` enforcement/inference slice) **plus** net-new parser + AST + expression-semantic plumbing for the postfix `@ATTR` form.

**Why rejected:** the right shape, but hard-wired to a single attribute rather than reusable — **Option B is exactly this generalized**, and Option A achieves the same goal without breaking tooling. Kept only as the conceptual precursor to Option B.

---

## Option E — No language change: convention + static analysis / naming

> **Tooling intrusiveness: NON-INTRUSIVE.** No grammar change; a lint tool is additive (typically built on libdparse itself). See [Tooling & ecosystem intrusiveness](#tooling--ecosystem-intrusiveness).

*Rejected alternative.* Encode the capability by **naming convention** (e.g. suffix `_cs` / `_yields`) and/or an out-of-band **linter** (DScanner plugin, or a custom AST pass over the frontend) that flags CS-capable calls and verifies propagation, without touching the language.

| Pros | Cons |
|---|---|
| Zero compiler/fork risk; ships immediately; fully upstream-neutral. | **Not enforced by the type system** — guarantees are advisory; easy to bypass or forget. |
| Call-site visibility achievable via naming (`yieldNow()` reads as yielding). | Naming discipline is brittle across refactors, templates, aliases, and third-party code. |
| Can be layered under any other option later as a stepping stone. | A separate linter is its own maintenance burden and won't see template instantiations the way the frontend does. |

**Implementation cost:** Low–Medium (linter), or ~Zero (convention only).

**Why rejected:** advisory only — no compiler-enforced guarantee, which the propagation requirement demands. Still useful as a migration bridge.

---

## Comparison matrix

Options are ordered best-first. A and B are the same generalized mechanism; they differ only in the call-site marker spelling (`.ATTR` vs `@ATTR`).

| | A. Generalized `.ATTR` | B. Generalized `@ATTR` | C. Type token | D. Bespoke `@` | E. Convention/lint |
|---|---|---|---|---|---|
| Call-site visibility | **Strong (per call)** | **Strong (per call)** | Weak (looks like arg) | **Strong (per call)** | Weak–Medium |
| Propagation soundness | Strong | Strong | Automatic | Strong (inferred) | None (advisory) |
| New syntax? | No (reuses member-access) | **Yes (`@`)** | No | **Yes (`@`)** | No |
| Reuses existing frontend path | Minimal + `DotIdExp` hook | Minimal | Partial | Partial + new | n/a |
| Models `withFunc`/delegate forwarder | **Native** | **Native** | Clumsy | Needs extra rule | n/a |
| Upstreamable / low fork risk | No | No | **Yes** | No | **Yes** |
| Implementation cost | High (no parser work) | Very High | Low–Med | High | Low |
| Generality (future attrs) | **Yes** | **Yes** | No | No | No |
| Intrusive to 3rd-party parsers / editors? | **near-No** | **Yes** | No | **Yes** | No |
| Marker distinctiveness (human reader) | Medium (`.` reads like member) | **Strong (`@`)** | Weak | **Strong (`@`)** | Naming-dependent |

---

## Tooling & ecosystem intrusiveness

A change to the **compiler** is not the same as a change to the **language as the tooling ecosystem sees it**. Almost the entire D editor/IDE stack parses D source with its *own* parser — **not** the DMD/LDC frontend we're forking. So any change to *grammar* (not just semantics) breaks those tools until each is independently patched, and we do **not** control most of them.

**The dividing line:** changes that are only new *attributes* (declaration-side UDAs) or *semantic rules* parse fine with existing grammars and are **non-intrusive** to tooling. Changes that add new *expression/statement syntax* — specifically the `@` call-site marker `foo@CTX_SWITCH(args)` — are **intrusive**: third-party parsers encounter an unexpected `@` in expression position, fail to parse the **whole module**, and (because these tools degrade per-file, not per-line) silently disable their features for that file. **Option A's `.ATTR` spelling sidesteps this entirely** because member access is already valid grammar.

### What breaks, and the user-visible symptom

For any option that introduces the call-site `@ATTR` expression syntax (**B and D**; **A avoids this entirely** by using member-access spelling):

- **libdparse** (the community D parser library) — does not recognize postfix `@` on expressions → parse error. This is the root dependency for most of the list below, so a single libdparse gap cascades:
  - **DCD** (D Completion Daemon) → **GoToDefinition / GoToReferences / autocomplete stop working** for any file containing a call-site marker (and often for symbols it transitively needs from such files).
  - **serve-d / code-d** (the VS Code D extension) → diagnostics, hover, rename, outline, semantic highlight all degrade on affected files.
  - **dfmt** (formatter) → fails or corrupts formatting around the marker.
  - **D-Scanner** (linter/static analysis) → spurious parse errors, lint disabled for the file.
- **Visual D** (Visual Studio) and the **IntelliJ-D / JetBrains** plugin ship **independent** parsers/grammars → same breakage, separately.
- **Syntax highlighters** with their own grammars — TextMate/`.tmLanguage` bundles, **tree-sitter-d**, Pygments, GitHub Linguist → mis-highlight or error around `@` in call position (cosmetic but pervasive: GitHub/GitLab diffs, docs).
- **ctags / universal-ctags** D parser and **ddoc/ddox** doc generators → may mis-tag or skip affected declarations.

> Note: the **declaration-side** pieces — `@CTX_SWITCH` as a UDA on a function, and `callerAttr!"..."` / `callerAttrFake!"..."` as ordinary template aliases — parse with **existing** grammars and are **non-intrusive** in every option. Only the **`@` call-site marker** is the intrusive part — which is exactly why Option A's `.ATTR` spelling is the lead recommendation.

### Per-option intrusiveness

- **Option A (generalized `.ATTR`)** — **Near-non-intrusive.** Member-access spelling is already valid grammar → no parse failures; tooling degrades only on the marker token (e.g. an unresolved-symbol squiggle), not the whole file. GoToDefinition/References keep working for every other symbol.
- **Option B (generalized `@ATTR`)** — **Intrusive.** New `@ATTR` expression grammar → breaks the libdparse-based stack (DCD GoToDefinition/References, serve-d, dfmt, D-Scanner), Visual D, IntelliJ-D, and third-party highlighters until each is patched.
- **Option C (type token)** — **Non-intrusive.** No grammar change; a `ctxsw` parameter and `boom(CTXSW)` call are ordinary D. All editor tooling keeps working unchanged.
- **Option D (bespoke attribute + `@` call-site syntax)** — **Intrusive (same blast radius as B).** Identical `@ATTR` grammar.
- **Option E (convention/lint)** — **Non-intrusive.** No grammar change; a lint tool is purely additive (and itself typically built *on* libdparse, so it inherits, not breaks, the ecosystem).

### Mitigations (only relevant if the `@`-marker path B / D is chosen)

Since we own a **Weka-local fork**, the breakage is in the *surrounding tools*, not the compiler. Options to limit blast radius, in rough order of effort/robustness:

1. **Lexer-level concealment for non-fork tools.** Make the marker lexically skippable — e.g. spell it as something existing grammars already tolerate (a special comment/pragma form, or a `mixin`/template-call wrapper) so libdparse/highlighters see valid tokens. Trades syntactic elegance for zero ecosystem breakage. *(Feasibility depends on Q4's chosen spelling — flagged there.)*
2. **Patch + vendor libdparse.** Maintain a fork of libdparse with the new grammar and rebuild DCD/serve-d/dfmt/D-Scanner against it. High maintenance (mirrors the compiler-fork cost across N tools) but preserves real tooling.
3. **Editor-side preprocessing.** A thin layer that strips/normalizes `@ATTR` markers before handing source to DCD/dfmt, restoring them after. Brittle for rename/refactor.
4. **Accept degraded tooling on marked files**, relying on the compiler for correctness and treating editor features as best-effort. Lowest effort, worst developer experience.

This is the **core trade-off between Options A and B (Q4)**: **Option A *is* mitigation 1 done properly** — it uses real member-access grammar instead of a comment/pragma kludge, so it sidesteps the entire intrusiveness problem without any of the mitigations above. Unless Option B's stronger visual distinctiveness is worth breaking the tooling ecosystem, **Option A is the answer**.

---

## Decision

**Chosen: the generalized, user-definable caller-required-attribute facility — Option A or B.** The mechanism is settled; the only open choice is the call-site marker spelling: **A (`.ATTR`, recommended)** vs **B (`@ATTR`)** — decided in Q4. The settled requirements driving this:

- **Mandatory call-site visibility.** A reader must be able to look at *the call itself* and know whether it context-switches; signature-only visibility is insufficient. → a per-call-site marker is required.
- **Enforced upward propagation.** A function that is not `CTX_SWITCH` may not call a `CTX_SWITCH` function. The capability propagates strictly upward to exactly **one root** — the fiber main function — which is declared `CTX_SWITCH` at the top, closing the tree.
- **Reusable mechanism.** The facility is generic (`callerAttr`); `CTX_SWITCH` is just the first client.
- **"Fake" migration mode.** Converting the whole source tree at once is infeasible, so a "fake" mode lets a function carry/forward the attribute (or call CS functions) *without* yet forcing the requirement onto its callers — a deliberate, greppable migration boundary.
- **Weka-local fork.** Upstreaming is not required, so new syntax (Option B) is on the table — though Option A's member-access spelling avoids any grammar change and the resulting tooling breakage.

**Recommendation:** prefer **Option A (`.ATTR`)** — near-zero ecosystem cost and lower compiler cost; its price is the member-access collision rule (Q6). Choose **Option B (`@ATTR`)** only if its stronger visual distinctiveness is judged worth breaking the third-party tooling ecosystem (DCD GoToDefinition/References, serve-d, dfmt, Visual D, IntelliJ-D).

Options C, D, E are retained above as **rejected alternatives**: C/E give insufficient call-site visibility/enforcement; D is the right shape but hard-wired to one attribute rather than reusable (Option B is D generalized — so D's implementation notes are a strict subset of B's).

The remaining open points (spelling A vs B, inference vs. explicit annotation, exact "fake" semantics, attribute identity across modules) are captured in the **Open questions** section below; everything else is specified in the design section that follows.

---

## Chosen design — Options A/B in detail

This section specifies the shared mechanism. Everything is spelling-agnostic except **step 3 (the call-site marker)**, which gives both the A (`.ATTR`) and B (`@ATTR`) forms.

### 1. Declaring an attribute

A caller-required attribute is introduced once, in library code, and given a compile-time identity:

```d
// druntime / weka runtime
alias CTX_SWITCH      = callerAttr!("CTX_SWITCH");          // the real attribute
alias CTX_SWITCH_FAKE = callerAttrFake!("CTX_SWITCH");      // migration escape hatch for the same attribute
```

`callerAttr!"Name"` yields a compiler-recognized UDA whose **identity is the string name** (so the same name in two modules refers to the same attribute — see Q3 on identity model). `callerAttrFake!"Name"` refers to the *same* attribute but flips the propagation behavior (step 4).

### 2. Marking declarations

Any function (and, for forwarders, any *delegate/function-pointer parameter*) can carry the attribute:

```d
@CTX_SWITCH void foo();                        // foo may context-switch
@CTX_SWITCH void withFunc(@CTX_SWITCH void delegate() dg);  // param dg is CS-capable
```

The **root** of the capability tree is just a function the programmer declares `@CTX_SWITCH` at the top (the fiber main); nothing calls it without itself being `@CTX_SWITCH`, so the tree is closed.

### 3. Mandatory call-site marker (the hard requirement)

Calling a function/delegate that carries attribute `X` **must** be written with a postfix marker, or it is a compile error; conversely writing the marker on a non-`X` call is also an error (the marker must match reality). The marker is spelled per the chosen option:

**Option A — `.ATTR` form (member-access spelling, recommended):**

```d
@CTX_SWITCH void g() {
    foo.CTX_SWITCH();                 // OK — marker matches
    withFunc.CTX_SWITCH({
        bar.CTX_SWITCH();
    });
    plain();                          // OK — plain() is not @CTX_SWITCH, no marker
    foo();                            // ERROR: call to @CTX_SWITCH `foo` must be marked `foo.CTX_SWITCH(...)`
}
```

**Option B — `@ATTR` form:**

```d
@CTX_SWITCH void g() {
    foo@CTX_SWITCH();                 // OK — marker matches
    withFunc@CTX_SWITCH({             // OK
        bar@CTX_SWITCH();             // delegate body is itself CS-capable
    });
    plain();                          // OK
    foo();                            // ERROR: call to @CTX_SWITCH `foo` must be marked `foo@CTX_SWITCH(...)`
}
```

Grammar:
- **Option A:** no grammar change — `callee.ATTR(args)` is parsed as an ordinary `DotIdExp`; the compiler intercepts it semantically when `ATTR` resolves to a `callerAttr` alias (collision rule: Q6).
- **Option B:** a postfix `@Identifier` between callee and arguments — `PostfixExpression '@' Identifier '(' Arguments ')'`. New expression grammar (parser + AST work; intrusive to tooling).

### 4. Propagation rule

For a real attribute `X` (`callerAttr`):

> A function body that contains a call marked with `X` is itself required to carry `@X`. A function **not** carrying `@X` that performs an `X`-marked call is a compile error (it must be annotated `@X`). Capability therefore propagates strictly upward to the single root.

This is the `@nogc` enforcement direction reused (`checkNogc` → `checkCallerAttr`), but with the **call-site marker** as the additional gate.

### 5. The "fake" mode (migration)

`callerAttrFake!"X"` exists so the tree can be converted incrementally instead of in one mega-commit. A `@X_FAKE` function:

- **is allowed to make `X`-marked calls** (so you can start threading the attribute through hot paths), **but**
- **does not propagate the requirement to its callers** — callers may call it *without* a marker and without being `@X` themselves.

This makes `@X_FAKE` a deliberate, greppable soundness hole that marks "migration boundary — not yet fully threaded." It also covers the forwarder case from your example (`withFunc` annotated fake while its `@X` delegate parameter is honored). **Q2** pins down whether "fake" should additionally require the call-site marker (for visibility) even though it doesn't propagate.

### 6. Interactions to specify (tracked, not yet decided)

- **Delegates / function pointers:** the attribute is part of the *type* (`@CTX_SWITCH void delegate()`); calling such a delegate needs the marker. Implies a `TypeFunction` flag (`mtype.d:3047`) and mangling consideration.
- **Templates / `auto` / lambdas:** inference vs. explicit (Q1).
- **Function pointers stored in variables, virtual calls, `opCall`, UFCS, `alias`:** marker placement rules needed.
- **`__traits`/reflection:** expose "has caller-attr X" for tooling.
- **Mangling & separate compilation:** does the attribute affect the symbol name (like `@nogc` does not, but `extern(C++)` ABI tags do)? Affects linking against unconverted libraries during migration.

---

## Open questions (remaining before implementation)

1. **Inference vs. explicit annotation for propagation.** When `g` calls an `@CTX_SWITCH` function, do you want `g` to be **inferred** `@CTX_SWITCH` automatically (less annotation churn, but the propagation becomes invisible at `g`'s declaration), or must `g` be **explicitly** annotated `@CTX_SWITCH` or it errors (maximally explicit, matches "you always see it", but more verbose)? Note: the *call-site* marker is mandatory regardless; this question is only about whether the *function header* annotation is auto-inferred. For templates/lambdas/`auto`, do you want the `@nogc` hybrid (infer for templates, require for non-templates)?
   <<answer here>>
2. **Exact "fake" semantics.** A `@X_FAKE` function does not propagate `@X` to its callers. But should an `@X_FAKE` function still be **required to mark** its own internal `X` calls? Two flavors: (a) *strict-fake* — marker still required inside (keeps visibility, only propagation is suppressed); (b) *loose-fake* — no marker required inside (truly "turn it all off here" for fastest migration). Which do you want — or both, as two different fake aliases?
   <<answer here>>
3. **Attribute identity across modules.** Should two `callerAttr!"CTX_SWITCH"` aliases declared in different modules be the **same** attribute (identity = the string name), or should identity be the **alias symbol** (so you must import the one canonical `CTX_SWITCH` declaration)? Symbol identity is safer (no accidental string collisions) but forces a shared import; string identity is looser and simpler.
   <<answer here>>
4. **Call-site marker spelling — A vs B (the central choice).** Member-access `.` ([Option A](#option-a--generalized-callerattr-with-attr-call-site-marker-member-access--recommended), recommended) or postfix `@` ([Option B](#option-b--generalized-callerattr-with-attr-call-site-marker))? A is **near-non-intrusive** to tooling and lower compiler cost, but introduces member-access ambiguity (Q6); B is more visually distinctive but breaks the third-party parser ecosystem. (A prefix `@CTX_SWITCH foo(args)` form is a third, less-favored possibility.) And for templates: `foo!(T).CTX_SWITCH(args)` / `foo!(T)@CTX_SWITCH(args)`? **Recommendation: Option A.**
   <<answer here>>
5. **Scope of "call".** Besides direct calls, which of these must carry the marker: delegate/function-pointer invocation through a variable, virtual method calls, `opCall`/operator overloads that may switch, and `alias`-ed calls? (Confirm "all invocations of an `@X`-typed callable" is the rule.)
   <<answer here>>
6. **(Only if Option A / `.ATTR` spelling chosen) Member-access collision rule.** Since `foo.CTX_SWITCH` is grammatically a member access, what happens when a real member or UFCS function named `CTX_SWITCH` is also in scope? Options: (a) the `callerAttr` alias interpretation always wins (shadows real members of that name — simplest, but can hide a real member); (b) it's a hard error (ambiguous); (c) the marker only applies when `CTX_SWITCH` resolves to a visible `callerAttr` alias and there is no member of that name, else fall back to normal member access. Also: must the alias be imported/visible in the calling scope for the marker to be recognized?
   <<answer here>>

---

## Appendix: concrete frontend touch-points (Options A / B / D)

- Marker definition: `runtime/druntime/src/core/attribute.d` (pattern: `enum ctxswitch;`).
- Recognition: extend `isCoreUda`/`isEnumAttribute` (`dmd/attrib.d:1246`/`:1325`); add `Id.udaCtxSwitch`.
- New STC bit: `dmd/astenums.d:42` (`STC` enum) + mirror flag on `TypeFunction` (`dmd/mtype.d:3047`).
- Enforcement: new `checkCtxSwitch` beside `checkNogc` (`dmd/expressionsem.d:2174`), called from `checkFunctionAttributes` (`:16279`), invoked in `visit(CallExp)` (`:6625`), respecting an `ignoreAttributes`-style escape hatch (`expression.d:3553`).
- Inference: `STC.inference` flow in `semantic3` (`:282`) + new `ctxswitchViolation` field (`dmd/func.d:336` neighborhood).
- Call-site marker:
  - **Option A (`.ATTR`):** no parser change — intercept `DotIdExp` in `dmd/expressionsem.d` when the trailing identifier resolves to a `callerAttr` alias, before normal member lookup; add collision-resolution (Q6).
  - **Option B (`@ATTR`):** extend `parsePostExp` (`dmd/parse.d:8938`) for postfix `@ATTR`, add a new AST field on `CallExp`, plumb through `visit(CallExp)`. (Also applies to bespoke Option D.)

---

## Appendix: how the frontend works today (verified)

These facts shape the cost estimates throughout this spec (file:line references into this repo):

- Built-in compiler-recognized UDAs are defined in `runtime/druntime/src/core/attribute.d` as bare `enum` markers (e.g. `enum mustuse;` at line 292) or small structs (`gnuAbiTag`). LDC-specific ones live in `runtime/druntime/src/ldc/attributes.d`.
- A UDA is recognized as "special" via `isCoreUda` / `isEnumAttribute` (`dmd/attrib.d:1246`, `:1325`); `@mustuse` is the closest existing template — see `dmd/mustuse.d` (`hasMustUseAttribute`, `isMustUseAttribute`, `checkMustUse`).
- **Caller-must-match attribute checking already exists** for `@safe`/`@nogc`/`pure`/`nothrow`/`@live`. The enforcement hooks are `checkSafety`/`checkNogc` (`dmd/expressionsem.d:2101`, `:2174`), aggregated in `checkFunctionAttributes` (`:16279`) and invoked per call in `visit(CallExp)` (`:6625`, gated by `CallExp.ignoreAttributes` at `:6340`).
- **Attribute inference** for templates/lambdas/`auto` functions is driven by `STC.inference` (`dmd/astenums.d:105`) during `semantic3` (`dmd/semantic3.d:282`); violations are recorded in per-function fields like `safetyViolation`/`nogcViolation` (`dmd/func.d:336`).
- Function attributes are stored as `STC` bitflags (`dmd/astenums.d:42`) on `FuncDeclaration.storage_class` and mirrored on `TypeFunction` (`dmd/mtype.d:3047`).
- **There is NO existing syntax for attributes on expressions / call sites.** `parsePostExp` (`dmd/parse.d:8938`) handles `.`, `++`, `()`, `[]` only — no `@` token. `@`-attributes are parsed for declarations only (`parseAttribute` `dmd/parse.d:1285`).
- **`@nocapture` does not exist** in this codebase (zero hits). Option C assumes a `@nocapture` import from `core.attribute` that is not present today — it would itself be new work.

The single most important consequence: **enforcing/propagating a function attribute reuses a well-trodden path (the `@nogc` machinery), but a mandatory `@` call-site syntax is genuinely new parser + semantic surface with no precedent in the language** (which is exactly why Option A's `.ATTR` member-access spelling is the lead recommendation — it needs no grammar change).
