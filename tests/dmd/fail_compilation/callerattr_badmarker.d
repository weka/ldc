import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

void plain() {}

@mayYield void caller()
{
    plain@mayYield();   // error: plain is not a @mayYield function
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_badmarker.d(8): Error: `callerattr_badmarker.plain` is not a `@mayYield` function; remove the `@mayYield` marker
---
*/
