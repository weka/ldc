import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

void oops()
{
    yieldNow() @CTX_SWITCH;   // error: oops is not @CTX_SWITCH
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_propagation.d(8): Error: non-`@CTX_SWITCH` function `callerattr_propagation.oops` cannot call `@CTX_SWITCH` function `callerattr_propagation.yieldNow`
---
*/
