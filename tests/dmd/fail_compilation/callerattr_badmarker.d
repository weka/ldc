import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

void plain() {}

@CTX_SWITCH void caller()
{
    plain() @CTX_SWITCH;   // error: plain is not a @CTX_SWITCH function
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_badmarker.d(8): Error: `callerattr_badmarker.plain` is not a `@CTX_SWITCH` function; remove the `@CTX_SWITCH` marker
---
*/
