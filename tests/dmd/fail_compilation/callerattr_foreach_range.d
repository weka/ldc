// A `foreach` over a range whose iteration primitives (`empty`/`front`/`popFront`) are
// @mayYield propagates the attribute to the enclosing function (E1). The compiler-generated
// primitive calls are implicitly marked (there is no place for a user marker), but the
// requirement that the enclosing function itself carry @mayYield is NOT waived: a
// non-@mayYield function may not host such a loop.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

struct SwitchingRange
{
    int i, n;
    @mayYield bool empty()    { yieldNow@mayYield(); return i >= n; }
    @mayYield int  front()    { return i; }
    @mayYield void popFront() { yieldNow@mayYield(); ++i; }
}

@mayYield void good()
{
    int s;
    foreach (v; SwitchingRange(0, 3)) { s += v; }   // ok: enclosing carries @mayYield
}

void bad()
{
    int s;
    foreach (v; SwitchingRange(0, 3)) { s += v; }   // build should fail here (E1)
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@mayYield` function `callerattr_foreach_range.bad` cannot call `@mayYield` function `callerattr_foreach_range.SwitchingRange.empty`
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@mayYield` function `callerattr_foreach_range.bad` cannot call `@mayYield` function `callerattr_foreach_range.SwitchingRange.popFront`
fail_compilation/callerattr_foreach_range.d(28): Error: non-`@mayYield` function `callerattr_foreach_range.bad` cannot call `@mayYield` function `callerattr_foreach_range.SwitchingRange.front`
---
*/
