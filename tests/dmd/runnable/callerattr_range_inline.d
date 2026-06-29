// PERMUTE_ARGS: -inline -O -release -g
// Companion to callerattr_inline.d (which covers the opApply foreach lowering). This covers the
// OTHER foreach lowering: the range protocol (empty/front/popFront).
//
// A range whose iteration primitives are themselves @CTX_SWITCH (e.g. a lazy range that does I/O
// on advance) must be iterable with `foreach`: the compiler-generated `__r.empty`/`__r.front`/
// `__r.popFront` calls carry the caller-attr and propagate to the enclosing function, exactly as
// a @CTX_SWITCH opApply does. Verified to hold under inlining/optimization.
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";

__gshared int switches;
pragma(inline, true) @CTX_SWITCH void yieldNow() { ++switches; }

// (A) A range whose iteration primitives context-switch (lazy/RPC-like). The foreach lowering's
//     generated __r.empty / __r.front / __r.popFront calls are @CTX_SWITCH and must be auto-marked
//     by the compiler (the user cannot annotate a compiler-generated call).
struct SwitchingRange {
    int i, n;
    pragma(inline, true) @CTX_SWITCH bool empty()    { yieldNow@CTX_SWITCH(); return i >= n; }
    pragma(inline, true) @CTX_SWITCH int  front()    { return i; }
    pragma(inline, true) @CTX_SWITCH void popFront() { yieldNow@CTX_SWITCH(); ++i; }
}

@CTX_SWITCH_FAKE int sumSwitchingRange() {
    int s;
    foreach (v; SwitchingRange(0, 4)) { s += v; }   // iteration itself switches; body does not
    return s;
}

// (B) A plain range, but with a context-switching BODY (body is inlined into the enclosing fn,
//     so the switch is an ordinary marked call — no special lowering support needed).
struct PlainRange {
    int i, n;
    pragma(inline, true) bool empty()    { return i >= n; }
    pragma(inline, true) int  front()    { return i; }
    pragma(inline, true) void popFront() { ++i; }
}

@CTX_SWITCH_FAKE int sumPlainRangeSwitchingBody() {
    int s;
    foreach (v; PlainRange(0, 4)) { yieldNow@CTX_SWITCH(); s += v; }
    return s;
}

void main() {
    switches = 0;
    assert(sumSwitchingRange() == 6);            // 0+1+2+3
    // empty() is called 5x (i=0..3 false, i=4 true) and popFront() 4x; each yieldNow()s.
    // front() is @CTX_SWITCH too (its generated call must be auto-marked) but doesn't yield.
    assert(switches == 9);

    switches = 0;
    assert(sumPlainRangeSwitchingBody() == 6);
    assert(switches == 4);                        // body switched once per element
}
