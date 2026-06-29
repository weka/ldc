// PERMUTE_ARGS: -inline -O -release -g
// Caller-required attributes (@CTX_SWITCH) must behave correctly under inlining/optimization.
// Caller-attr is a compile-time-only check, but the fork makes it participate in name mangling
// for overload-set siblings (plain vs @CTX_SWITCH). Inlining and linking resolve by mangled
// name, so this exercises, with -inline -O:
//   1. a pragma(inline,true) @CTX_SWITCH function still enforces the marker and runs correctly;
//   2. a dual opApply overload set (plain vs @CTX_SWITCH) selects & inlines the CORRECT overload
//      (a mangling/inlining mismatch would mis-dispatch or fail to link);
//   3. foreach over an array with a context-switching body (body inlined into the enclosing fn).
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";

// Observable stand-in for "a context switch happened".
__gshared int switches;

pragma(inline, true) @CTX_SWITCH void yieldNow() { ++switches; }

// (1) A pragma(inline,true) @CTX_SWITCH function: the marker is still required at the call site,
//     and the inlined call must produce the right result.
pragma(inline, true) @CTX_SWITCH int doubled(int x) { yieldNow() @CTX_SWITCH; return x * 2; }
@CTX_SWITCH_FAKE int useDoubled(int x) { return doubled(x) @CTX_SWITCH; }

// (2) Dual opApply: plain vs @CTX_SWITCH. The two overloads differ only by the caller-attr, so
//     the fork must keep them as distinct symbols (mangling discriminator). Both are force-inlined.
//     The @CTX_SWITCH overload bumps `switches` so we can observe which one actually ran.
struct Container {
    int[3] data;

    pragma(inline, true) int opApply(scope int delegate(int) dg) {
        int r;
        foreach (v; data) { r = dg(v); if (r) return r; }
        return 0;
    }

    pragma(inline, true) @CTX_SWITCH int opApply(scope @CTX_SWITCH int delegate(int) dg) {
        int r;
        foreach (v; data) { ++switches; r = dg(v) @CTX_SWITCH; if (r) return r; }
        return 0;
    }
}

// Non-switching body -> binds the PLAIN opApply.
int sumPlain(ref Container c) {
    int s;
    foreach (v; c) { s += v; }
    return s;
}

// Switching body -> binds the @CTX_SWITCH opApply.
@CTX_SWITCH_FAKE int sumViaOpApply(ref Container c) {
    int s;
    foreach (v; c) { yieldNow() @CTX_SWITCH; s += v; }
    return s;
}

// (3) foreach over an array with a switching body: the body is inlined into the enclosing
//     function (no opApply delegate), so the switch is just an ordinary marked call.
@CTX_SWITCH_FAKE int sumArray(const(int)[] xs) {
    int s;
    foreach (v; xs) { yieldNow() @CTX_SWITCH; s += v; }
    return s;
}

void main() {
    // (1)
    assert(useDoubled(21) == 42);

    Container c;
    c.data = [10, 20, 30];

    // (2) plain overload selected: correct sum, and the @CTX_SWITCH overload (which bumps
    //     `switches`) must NOT have run.
    switches = 0;
    assert(sumPlain(c) == 60);
    assert(switches == 0);

    // (2) @CTX_SWITCH overload selected: correct sum, and it (plus yieldNow) must have run.
    switches = 0;
    assert(sumViaOpApply(c) == 60);
    assert(switches == 6);   // 3 from opApply's ++switches + 3 from yieldNow in the body

    // (3)
    switches = 0;
    assert(sumArray([1, 2, 3, 4]) == 10);
    assert(switches == 4);
}
