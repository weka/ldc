// Negative cases around @mayYield and foreach/opApply.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

struct CtxContainer
{
    int[2] data;
    int opApply(scope int delegate(int) dg)
    { foreach (x; data) if (auto r = dg(x)) return r; return 0; }
    
    @mayYield int opApply(scope @mayYield int delegate(int) dg)
    { foreach (x; data) if (auto r = dg@mayYield(x)) return r; return 0; }
}

// (a) calling a @mayYield function WITHOUT the marker, inside a foreach body -> must be marked (E2)
void missingMarkerInForeach()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow();
    }
}

// (b) a non-@mayYield function running a marked @mayYield call -> cannot call (E1)
void directCallNoAttr()
{
    yieldNow@mayYield();
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach_unmarked.d(22): Error: call to `@mayYield` function `callerattr_foreach_unmarked.yieldNow` must be marked `yieldNow@mayYield()`
fail_compilation/callerattr_foreach_unmarked.d(29): Error: non-`@mayYield` function `callerattr_foreach_unmarked.directCallNoAttr` cannot call `@mayYield` function `callerattr_foreach_unmarked.yieldNow`
---
*/
