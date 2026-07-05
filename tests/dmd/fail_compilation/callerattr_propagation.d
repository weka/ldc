import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

void oops()
{
    yieldNow@mayYield();   // error: oops is not @mayYield
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_propagation.d(8): Error: non-`@mayYield` function `callerattr_propagation.oops` cannot call `@mayYield` function `callerattr_propagation.yieldNow`
---
*/
