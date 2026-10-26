// PERMUTE_ARGS: -inline -O -release -g
// Companion to callerattr_inline.d (which covers the opApply foreach lowering). This covers the
// OTHER foreach lowering: the range protocol (empty/front/popFront).
//
// A range whose iteration primitives are themselves @mayYield (e.g. a lazy range that does I/O
// on advance) must be iterable with `foreach`: the compiler-generated `__r.empty`/`__r.front`/
// `__r.popFront` calls carry the caller-attr and propagate to the enclosing function, exactly as
// a @mayYield opApply does. Verified to hold under inlining/optimization.
import core.attribute : callerAttr, callerAttrUnchecked;
alias mayYield      = callerAttr!"mayYield";
alias mayYieldUnchecked = callerAttrUnchecked!"mayYield";

__gshared int switches;
pragma(inline, true) @mayYield void yieldNow() { ++switches; }

// (A) A range whose iteration primitives context-switch (lazy/RPC-like). The foreach lowering's
//     generated __r.empty / __r.front / __r.popFront calls are @mayYield and must be auto-marked
//     by the compiler (the user cannot annotate a compiler-generated call).
struct SwitchingRange {
    int i, n;
    pragma(inline, true) @mayYield bool empty()    { yieldNow@mayYield(); return i >= n; }
    pragma(inline, true) @mayYield int  front()    { return i; }
    pragma(inline, true) @mayYield void popFront() { yieldNow@mayYield(); ++i; }
}

@mayYieldUnchecked int sumSwitchingRange() {
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

@mayYieldUnchecked int sumPlainRangeSwitchingBody() {
    int s;
    foreach (v; PlainRange(0, 4)) { yieldNow@mayYield(); s += v; }
    return s;
}

void main() {
    switches = 0;
    assert(sumSwitchingRange() == 6);            // 0+1+2+3
    // empty() is called 5x (i=0..3 false, i=4 true) and popFront() 4x; each yieldNow()s.
    // front() is @mayYield too (its generated call must be auto-marked) but doesn't yield.
    assert(switches == 9);

    switches = 0;
    assert(sumPlainRangeSwitchingBody() == 6);
    assert(switches == 4);                        // body switched once per element
}
