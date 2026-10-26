import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

@mayYield void worker()
{
    yieldNow();   // error: missing the @mayYield marker
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_unmarked.d(8): Error: call to `@mayYield` function `callerattr_unmarked.yieldNow` must be marked `yieldNow@mayYield()`
---
*/
