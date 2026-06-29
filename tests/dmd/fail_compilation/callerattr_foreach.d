// A context-switching `foreach` body (lowered to a delegate passed to the aggregate's opApply)
// propagates @CTX_SWITCH to the enclosing function: a non-@CTX_SWITCH function may not host one.
import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

struct CtxContainer
{
    int[2] data;
    
    int opApply(scope int delegate(int) dg) { 
        foreach (x; data) 
            if (auto r = dg(x)) return r; 
        return 0; 
    }
    
    @CTX_SWITCH int opApply(scope @CTX_SWITCH int delegate(int) dg) { 
        foreach (x; data) 
            if (auto r = dg@CTX_SWITCH(x)) return r; 
        return 0; 
    }
}

@CTX_SWITCH void good()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow@CTX_SWITCH(); 
    }
}

void bad()
{
    CtxContainer c;
    foreach (x; c) { 
        yieldNow@CTX_SWITCH(); // build should fail here
    } 
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_foreach.d(37): Error: non-`@CTX_SWITCH` function `callerattr_foreach.bad` context-switches here (via `foreach` over `@CTX_SWITCH` function `callerattr_foreach.CtxContainer.opApply`)
---
*/
