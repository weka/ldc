// Caller-required attributes on delegate / function-pointer parameters (indirect calls).
import core.attribute : callerAttr, callerAttrUnchecked;
alias mayYield      = callerAttr!"mayYield";
alias mayYieldUnchecked = callerAttrUnchecked!"mayYield";

// E2: a @mayYield delegate called without the marker.
@mayYieldUnchecked void unmarked(@mayYield void delegate() dg)
{
    dg();
}

// E2 with `scope`: scope does not change enforcement.
@mayYieldUnchecked void unmarkedScope(@mayYield scope void delegate() dg)
{
    dg();
}

// E1: a non-@mayYield function calling a @mayYield delegate (marked).
void notCs(@mayYield void delegate() dg)
{
    dg@mayYield();
}

// E3: a marker on a plain delegate that carries no caller-attribute.
@mayYield void bogus(void delegate() dg)
{
    dg@mayYield();
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_delegate.d(9): Error: call to `@mayYield` function `callerattr_delegate.unmarked.dg` must be marked `dg@mayYield()`
fail_compilation/callerattr_delegate.d(15): Error: call to `@mayYield` function `callerattr_delegate.unmarkedScope.dg` must be marked `dg@mayYield()`
fail_compilation/callerattr_delegate.d(21): Error: non-`@mayYield` function `callerattr_delegate.notCs` cannot call `@mayYield` function `callerattr_delegate.notCs.dg`
fail_compilation/callerattr_delegate.d(27): Error: `callerattr_delegate.bogus.dg` is not a `@mayYield` function; remove the `@mayYield` marker
---
*/
