// A context-switching lambda must not leak into a non-@mayYield delegate parameter.
// The lambda infers @mayYield from its body; passing it to a plain `void delegate()`
// parameter would let a non-CS context drive a context switch, so it is rejected.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

void withDgPlain(void delegate() dg)
{
    dg();
}

void runPlainWithLambda()
{
    withDgPlain(() {
        yieldNow@mayYield();
    });
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_lambda_leak.d(16): Error: cannot pass `@mayYield` lambda to non-`@mayYield` parameter `dg`
---
*/
