// A context-switching `foreach` body (lowered to a delegate passed to the aggregate's opApply)
// propagates @mayYield to the enclosing function: a non-@mayYield function may not host one.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

struct CtxContainer
{
    int[2] data;
    
    int opApply(scope int delegate(int) dg) { 
        foreach (x; data) 
            if (auto r = dg(x)) return r; 
        return 0; 
    }
    
    @mayYield int opApply(scope @mayYield int delegate(int) dg) { 
        foreach (x; data) 
            if (auto r = dg@mayYield(x)) return r; 
        return 0; 
    }
}

@mayYield void good()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow@mayYield(); 
    }
}

void bad()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow@mayYield(); // build should fail here
    } 
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach.d(37): Error: non-`@mayYield` function `callerattr_foreach.bad` context-switches here (via `foreach` over `@mayYield` function `callerattr_foreach.CtxContainer.opApply`)
---
*/
