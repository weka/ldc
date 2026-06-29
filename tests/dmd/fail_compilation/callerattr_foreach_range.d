// A `foreach` over a range whose iteration primitives (`empty`/`front`/`popFront`) are
// @CTX_SWITCH propagates the attribute to the enclosing function (E1). The compiler-generated
// primitive calls are implicitly marked (there is no place for a user marker), but the
// requirement that the enclosing function itself carry @CTX_SWITCH is NOT waived: a
// non-@CTX_SWITCH function may not host such a loop.
import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

struct SwitchingRange
{
    int i, n;
    @CTX_SWITCH bool empty()    { @CTX_SWITCH yieldNow(); return i >= n; }
    @CTX_SWITCH int  front()    { return i; }
    @CTX_SWITCH void popFront() { @CTX_SWITCH yieldNow(); ++i; }
}

@CTX_SWITCH void good()
{
    int s;
    foreach (v; SwitchingRange(0, 3)) { s += v; }   // ok: enclosing carries @CTX_SWITCH
}

void bad()
{
    int s;
    foreach (v; SwitchingRange(0, 3)) { s += v; }   // build should fail here (E1)
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@CTX_SWITCH` function `callerattr_foreach_range.bad` cannot call `@CTX_SWITCH` function `callerattr_foreach_range.SwitchingRange.empty`
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@CTX_SWITCH` function `callerattr_foreach_range.bad` cannot call `@CTX_SWITCH` function `callerattr_foreach_range.SwitchingRange.popFront`
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@CTX_SWITCH` function `callerattr_foreach_range.bad` cannot call `@CTX_SWITCH` function `callerattr_foreach_range.SwitchingRange.front`
---
*/
