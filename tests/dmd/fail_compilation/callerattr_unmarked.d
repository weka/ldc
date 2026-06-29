import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

@CTX_SWITCH void worker()
{
    yieldNow();   // error: missing the @CTX_SWITCH marker
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_unmarked.d(8): Error: call to `@CTX_SWITCH` function `callerattr_unmarked.yieldNow` must be marked `@CTX_SWITCH yieldNow()`
---
*/
