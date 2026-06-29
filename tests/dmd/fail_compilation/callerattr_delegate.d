// Caller-required attributes on delegate / function-pointer parameters (indirect calls).
import core.attribute : callerAttr, callerAttrFake;
alias CTX_SWITCH      = callerAttr!"CTX_SWITCH";
alias CTX_SWITCH_FAKE = callerAttrFake!"CTX_SWITCH";

// E2: a @CTX_SWITCH delegate called without the marker.
@CTX_SWITCH_FAKE void unmarked(@CTX_SWITCH void delegate() dg)
{
    dg();
}

// E2 with `scope`: scope does not change enforcement.
@CTX_SWITCH_FAKE void unmarkedScope(@CTX_SWITCH scope void delegate() dg)
{
    dg();
}

// E1: a non-@CTX_SWITCH function calling a @CTX_SWITCH delegate (marked).
void notCs(@CTX_SWITCH void delegate() dg)
{
    @CTX_SWITCH dg();
}

// E3: a marker on a plain delegate that carries no caller-attribute.
@CTX_SWITCH void bogus(void delegate() dg)
{
    @CTX_SWITCH dg();
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_delegate.d(9): Error: call to `@CTX_SWITCH` function `callerattr_delegate.unmarked.dg` must be marked `@CTX_SWITCH dg()`
fail_compilation/callerattr_delegate.d(15): Error: call to `@CTX_SWITCH` function `callerattr_delegate.unmarkedScope.dg` must be marked `@CTX_SWITCH dg()`
fail_compilation/callerattr_delegate.d(21): Error: non-`@CTX_SWITCH` function `callerattr_delegate.notCs` cannot call `@CTX_SWITCH` function `callerattr_delegate.notCs.dg`
fail_compilation/callerattr_delegate.d(27): Error: `callerattr_delegate.bogus.dg` is not a `@CTX_SWITCH` function; remove the `@CTX_SWITCH` marker
---
*/
