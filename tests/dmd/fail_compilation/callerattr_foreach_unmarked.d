// Negative cases around @CTX_SWITCH and foreach/opApply.
import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

struct CtxContainer
{
    int[2] data;
    int opApply(scope int delegate(int) dg)
    { foreach (x; data) if (auto r = dg(x)) return r; return 0; }
    
    @CTX_SWITCH int opApply(scope @CTX_SWITCH int delegate(int) dg)
    { foreach (x; data) if (auto r = dg@CTX_SWITCH(x)) return r; return 0; }
}

// (a) calling a @CTX_SWITCH function WITHOUT the marker, inside a foreach body -> must be marked (E2)
void missingMarkerInForeach()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow();
    }
}

// (b) a non-@CTX_SWITCH function running a marked @CTX_SWITCH call -> cannot call (E1)
void directCallNoAttr()
{
    yieldNow@CTX_SWITCH();
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach_unmarked.d(22): Error: call to `@CTX_SWITCH` function `callerattr_foreach_unmarked.yieldNow` must be marked `yieldNow@CTX_SWITCH()`
fail_compilation/callerattr_foreach_unmarked.d(29): Error: non-`@CTX_SWITCH` function `callerattr_foreach_unmarked.directCallNoAttr` cannot call `@CTX_SWITCH` function `callerattr_foreach_unmarked.yieldNow`
---
*/
