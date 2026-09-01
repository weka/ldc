// Option A: caller-required attributes with the glued `callee@ATTR(args)` call-site marker.
// These all compile cleanly.
import core.attribute : callerAttr, callerAttrUnchecked;
alias mayYield      = callerAttr!"mayYield";
alias mayYieldUnchecked = callerAttrUnchecked!"mayYield";

@mayYield void yieldNow() {}
void plain() {}

// Propagation: a @mayYield function may call @mayYield functions when marked.
@mayYield void worker()
{
    yieldNow@mayYield();   // marker matches; worker is @mayYield
    plain();                  // not CS, no marker needed
}

// The single root (e.g. the fiber main) starts the tree.
@mayYield void fiberMain()
{
    worker@mayYield();
}

// Forwarder via the FAKE migration shim: not forced onto its callers.
@mayYieldUnchecked void withLock(void delegate() dg)
{
    yieldNow@mayYield();   // strict-fake: internal CS call still marked
    dg();
}

void notYetMigrated()
{
    withLock(() {});          // calling a FAKE function needs no marker and no propagation
}

// Works on aggregate methods too.
struct Fiber
{
    @mayYield void yield() {}
    @mayYield void step() { this.yield@mayYield(); }
}

// ----------------------------------------------------------------------------
// Delegates / function pointers (indirect calls).
//
// A delegate parameter marked `@mayYield` is itself a context-switching callee:
// calling it requires the `dg@mayYield()` marker and propagates upward exactly like
// a named function. This holds whether or not the parameter is `scope`.
// A delegate parameter *without* `@mayYield` is an ordinary callee: no marker,
// no propagation.

// --- delegates that REQUIRE mayYield ---

// Non-scope @mayYield delegate, forwarded by a FAKE shim (no propagation to callers).
@mayYieldUnchecked void withDg(@mayYield void delegate() dg)
{
    yieldNow@mayYield();
    dg@mayYield();             // marked indirect call
}

// `scope` @mayYield delegate — same rules; `scope` does not change enforcement.
@mayYieldUnchecked void withScopeDg(@mayYield scope void delegate() dg)
{
    dg@mayYield();
}

// A real @mayYield function calling a @mayYield (scope) delegate: propagation holds.
@mayYield void runScoped(@mayYield scope void delegate() dg)
{
    dg@mayYield();
}

// @mayYield function-pointer parameter, called with the marker.
@mayYield void runFp(@mayYield void function() fp)
{
    fp@mayYield();
}

// (A context-switching lambda passed to a *plain* delegate parameter is rejected —
// see fail_compilation/callerattr_lambda_leak.d.)

// Both kinds side by side: `dg` requires the marker, `dg_no_ctx` does not.
@mayYield void runMixed(@mayYield void delegate() dg, void delegate() dg_no_ctx)
{
    withDg@mayYield(dg);

    // An in-place lambda that itself performs a context switch. The lambda infers
    // `@mayYield` from its body (like @nogc/@safe inference), so no annotation
    // and no FAKE shim are needed.
    withDg@mayYield(() {
        yieldNow@mayYield();
    });

    dg@mayYield();   // CS delegate: marker required
    dg_no_ctx();        // plain delegate: no marker
}

// --- delegates that DO NOT require mayYield ---

// Plain delegates (scope and non-scope): ordinary callees, no marker, callable
// from non-@mayYield code.
void eachScoped(scope void delegate() dg) { dg(); }
void each(void delegate() dg)             { dg(); }

// A non-@mayYield function receiving a non-@mayYield delegate: nothing here is
// context-switching, so no marker is needed and the function need not be @mayYield.
void runPlain(void delegate() dg_no_ctx)
{
    dg_no_ctx();
}

// A non-@mayYield function that calls a plain delegate (no context switch): fine.
// (Passing a *context-switching* lambda here is rejected — see
// fail_compilation/callerattr_lambda_leak.d.)
void withDgPlain(void delegate() dg)
{
    dg();
}

void usesWithDgPlain()
{
    withDgPlain(() {});   // plain lambda: no context switch, no marker
}

// IMPORTANT (the core safety rule): a function NOT marked @mayYield may NOT call a
// @mayYield callee. Each commented line below is a compile error — enforced and
// covered by fail_compilation/callerattr_propagation.d and callerattr_delegate.d:
//
//   void illegalNamed() {
//       yieldNow@mayYield();   // Error: non-`@mayYield` function `illegalNamed`
//                                 //        cannot call `@mayYield` function `yieldNow`
//   }
//   void illegalDg(@mayYield void delegate() dg) {
//       dg@mayYield();         // Error: non-`@mayYield` function `illegalDg`
//                                 //        cannot call `@mayYield` function `illegalDg.dg`
//   }

// Driving both kinds from non-CS code: calling a FAKE forwarder needs no marker
// and does not force the caller to be @mayYield; plain delegates need no marker.
void usesDelegates()
{
    withDg(() {});              // FAKE forwarder: no marker, no propagation
    withScopeDg(() {});
    each(() {});               // plain delegate: no marker
    eachScoped(() {});
}

// ----------------------------------------------------------------------------
// Regression: the call-site marker must survive template instantiation.
// CallExp.markedCallerAttr is set at parse time, so CallExp.syntaxCopy() must
// copy it — otherwise each template instantiation loses the marker and wrongly
// reports "call must be marked". A FAKE template instantiated with >1 arg keeps
// its internal marker across all instantiations.
@mayYieldUnchecked void suspendThisFiberT(bool withDelayFault = true)()
{
    yieldNow@mayYield();     // marker inside a templated body
}
void drivesTemplate()
{
    suspendThisFiberT!(true)();
    suspendThisFiberT!(false)();
}

// ----------------------------------------------------------------------------
// foreach over an aggregate's opApply: the loop body is lowered to a delegate passed to opApply.
// A container can offer both a plain and a @mayYield opApply; the caller-attr overload tie-break
// picks per body, and a context-switching body propagates @mayYield to the enclosing function
// (the compiler-generated foreach->opApply call is implicitly marked — no user marker possible).
struct CtxContainer
{
    int[2] data;
    // plain iteration
    int opApply(scope int delegate(int) dg)
    {
        foreach (x; data) { if (auto r = dg(x)) return r; }
        return 0;
    }
    // context-switching iteration (chosen when the loop body calls a @mayYield function)
    @mayYield int opApply(scope @mayYield int delegate(int) dg)
    {
        foreach (x; data) { if (auto r = dg@mayYield(x)) return r; }
        return 0;
    }
}

// plain body -> selects the plain opApply; no propagation, callable from non-@mayYield code.
void foreachPlain()
{
    CtxContainer c;
    foreach (x; c) { int y = x; }
}

// context-switching body -> selects the @mayYield opApply; the marker stays natural and the
// enclosing function must itself be @mayYield (propagation through foreach).
@mayYield void foreachCtxSwitch()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow@mayYield();
    }
}

// a FAKE function may host a context-switching foreach without forcing the requirement on its callers.
@mayYieldUnchecked void foreachCtxSwitchFake()
{
    CtxContainer c;
    foreach (x; c) { yieldNow@mayYield(); }
}
void drivesForeachFake() { foreachCtxSwitchFake(); }   // calling a FAKE: no marker, no propagation

// A @mayYield function may freely run ordinary (non-context-switching) foreach loops: a plain body
// selects the plain opApply, so the loop needs no marker and does not itself re-propagate. (This
// function is @mayYield for its own reasons — the direct marked call below.)
@mayYield void ctxFnWithPlainForeach()
{
    CtxContainer c;
    int sum;
    foreach (x; c) { sum += x; }    // plain body -> plain opApply, no @mayYield involved
    yieldNow@mayYield();          // the genuine context switch
}

// ----------------------------------------------------------------------------
// Method chaining: marking ONE call in a chain `a().b().c()`.
//
// The glued marker sits between a callee and that call's `(`, so it binds exactly that
// one call — no parentheses needed, in any position. step1()/step3() are plain;
// step2() is the only @mayYield hop.
struct Pipe
{
    int n;
    Pipe step1() { return Pipe(n + 1); }                                    // plain
    @mayYield Pipe step2() { yieldNow@mayYield(); return Pipe(n + 2); } // the only @mayYield hop
    Pipe step3() { return Pipe(n + 3); }                                    // plain
}

// Mark the MIDDLE call in step1().step2().step3(): just glue the marker to step2().
@mayYield void chainedMiddle()
{
    Pipe p;
    auto r = p.step1().step2@mayYield().step3();
}

// Mark the FIRST call.
@mayYield void chainedFirst()
{
    Pipe p;
    auto r = p.step2@mayYield().step1().step3();   // marks step2()
}

// Mark the LAST call.
@mayYield void chainedLast()
{
    Pipe p;
    auto r = p.step1().step3().step2@mayYield();   // marks step2()
}

// Templated call in a chain: the marker goes AFTER the `!(...)` template args and before
// the call `(` — `map!(int)@mayYield(x)`.
struct Gen
{
    @mayYield Gen map(T)(T x) { yieldNow@mayYield(); return this; }   // template, @mayYield
    Gen plain() { return this; }                                          // plain
}
@mayYield void chainedTemplate()
{
    Gen g;
    auto r = g.plain().map!(int)@mayYield(3).plain();   // marks map!(int)(3) only
}
