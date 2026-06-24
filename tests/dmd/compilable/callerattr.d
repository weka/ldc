// Option A: caller-required attributes with the postfix `() @ATTR` call-site marker.
// These all compile cleanly.
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}
void plain() {}

// Propagation: a @CTX_SWITCH function may call @CTX_SWITCH functions when marked.
@CTX_SWITCH void worker()
{
    yieldNow() @CTX_SWITCH;   // marker matches; worker is @CTX_SWITCH
    plain();                  // not CS, no marker needed
}

// The single root (e.g. the fiber main) starts the tree.
@CTX_SWITCH void fiberMain()
{
    worker() @CTX_SWITCH;
}

// Forwarder via the FAKE migration shim: not forced onto its callers.
@CTX_SWITCH_FAKE void withLock(void delegate() dg)
{
    yieldNow() @CTX_SWITCH;   // strict-fake: internal CS call still marked
    dg();
}

void notYetMigrated()
{
    withLock(() {});          // calling a FAKE function needs no marker and no propagation
}

// Works on aggregate methods too.
struct Fiber
{
    @CTX_SWITCH void yield() {}
    @CTX_SWITCH void step() { this.yield() @CTX_SWITCH; }
}

// ----------------------------------------------------------------------------
// Delegates / function pointers (indirect calls).
//
// A delegate parameter marked `@CTX_SWITCH` is itself a context-switching callee:
// calling it requires the `() @CTX_SWITCH` marker and propagates upward exactly like
// a named function. This holds whether or not the parameter is `scope`.
// A delegate parameter *without* `@CTX_SWITCH` is an ordinary callee: no marker,
// no propagation.

// --- delegates that REQUIRE CTX_SWITCH ---

// Non-scope @CTX_SWITCH delegate, forwarded by a FAKE shim (no propagation to callers).
@CTX_SWITCH_FAKE void withDg(@CTX_SWITCH void delegate() dg)
{
    yieldNow() @CTX_SWITCH;
    dg() @CTX_SWITCH;             // marked indirect call
}

// `scope` @CTX_SWITCH delegate — same rules; `scope` does not change enforcement.
@CTX_SWITCH_FAKE void withScopeDg(@CTX_SWITCH scope void delegate() dg)
{
    dg() @CTX_SWITCH;
}

// A real @CTX_SWITCH function calling a @CTX_SWITCH (scope) delegate: propagation holds.
@CTX_SWITCH void runScoped(@CTX_SWITCH scope void delegate() dg)
{
    dg() @CTX_SWITCH;
}

// @CTX_SWITCH function-pointer parameter, called with the marker.
@CTX_SWITCH void runFp(@CTX_SWITCH void function() fp)
{
    fp() @CTX_SWITCH;
}

// (A context-switching lambda passed to a *plain* delegate parameter is rejected —
// see fail_compilation/callerattr_lambda_leak.d.)

// Both kinds side by side: `dg` requires the marker, `dg_no_ctx` does not.
@CTX_SWITCH void runMixed(@CTX_SWITCH void delegate() dg, void delegate() dg_no_ctx)
{
    withDg(dg) @CTX_SWITCH;

    // An in-place lambda that itself performs a context switch. The lambda infers
    // `@CTX_SWITCH` from its body (like @nogc/@safe inference), so no annotation
    // and no FAKE shim are needed.
    withDg(() {
        yieldNow() @CTX_SWITCH;
    }) @CTX_SWITCH;

    dg() @CTX_SWITCH;   // CS delegate: marker required
    dg_no_ctx();        // plain delegate: no marker
}

// --- delegates that DO NOT require CTX_SWITCH ---

// Plain delegates (scope and non-scope): ordinary callees, no marker, callable
// from non-@CTX_SWITCH code.
void eachScoped(scope void delegate() dg) { dg(); }
void each(void delegate() dg)             { dg(); }

// A non-@CTX_SWITCH function receiving a non-@CTX_SWITCH delegate: nothing here is
// context-switching, so no marker is needed and the function need not be @CTX_SWITCH.
void runPlain(void delegate() dg_no_ctx)
{
    dg_no_ctx();
}

// A non-@CTX_SWITCH function that calls a plain delegate (no context switch): fine.
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

// IMPORTANT (the core safety rule): a function NOT marked @CTX_SWITCH may NOT call a
// @CTX_SWITCH callee. Each commented line below is a compile error — enforced and
// covered by fail_compilation/callerattr_propagation.d and callerattr_delegate.d:
//
//   void illegalNamed() {
//       yieldNow() @CTX_SWITCH;   // Error: non-`@CTX_SWITCH` function `illegalNamed`
//                                 //        cannot call `@CTX_SWITCH` function `yieldNow`
//   }
//   void illegalDg(@CTX_SWITCH void delegate() dg) {
//       dg() @CTX_SWITCH;         // Error: non-`@CTX_SWITCH` function `illegalDg`
//                                 //        cannot call `@CTX_SWITCH` function `illegalDg.dg`
//   }

// Driving both kinds from non-CS code: calling a FAKE forwarder needs no marker
// and does not force the caller to be @CTX_SWITCH; plain delegates need no marker.
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
@CTX_SWITCH_FAKE void suspendThisFiberT(bool withDelayFault = true)()
{
    yieldNow() @CTX_SWITCH;     // marker inside a templated body
}
void drivesTemplate()
{
    suspendThisFiberT!(true)();
    suspendThisFiberT!(false)();
}

// ----------------------------------------------------------------------------
// foreach over an aggregate's opApply: the loop body is lowered to a delegate passed to opApply.
// A container can offer both a plain and a @CTX_SWITCH opApply; the caller-attr overload tie-break
// picks per body, and a context-switching body propagates @CTX_SWITCH to the enclosing function
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
    // context-switching iteration (chosen when the loop body calls a @CTX_SWITCH function)
    @CTX_SWITCH int opApply(scope @CTX_SWITCH int delegate(int) dg)
    {
        foreach (x; data) { if (auto r = dg(x) @CTX_SWITCH) return r; }
        return 0;
    }
}

// plain body -> selects the plain opApply; no propagation, callable from non-@CTX_SWITCH code.
void foreachPlain()
{
    CtxContainer c;
    foreach (x; c) { int y = x; }
}

// context-switching body -> selects the @CTX_SWITCH opApply; the marker stays natural and the
// enclosing function must itself be @CTX_SWITCH (propagation through foreach).
@CTX_SWITCH void foreachCtxSwitch()
{
    CtxContainer c;
    foreach (x; c) { yieldNow() @CTX_SWITCH; }
}

// a FAKE function may host a context-switching foreach without forcing the requirement on its callers.
@CTX_SWITCH_FAKE void foreachCtxSwitchFake()
{
    CtxContainer c;
    foreach (x; c) { yieldNow() @CTX_SWITCH; }
}
void drivesForeachFake() { foreachCtxSwitchFake(); }   // calling a FAKE: no marker, no propagation

// A @CTX_SWITCH function may freely run ordinary (non-context-switching) foreach loops: a plain body
// selects the plain opApply, so the loop needs no marker and does not itself re-propagate. (This
// function is @CTX_SWITCH for its own reasons — the direct marked call below.)
@CTX_SWITCH void ctxFnWithPlainForeach()
{
    CtxContainer c;
    int sum;
    foreach (x; c) { sum += x; }    // plain body -> plain opApply, no @CTX_SWITCH involved
    yieldNow() @CTX_SWITCH;          // the genuine context switch
}
