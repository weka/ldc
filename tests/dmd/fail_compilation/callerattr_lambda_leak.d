// A context-switching lambda must not leak into a non-@CTX_SWITCH delegate parameter.
// The lambda infers @CTX_SWITCH from its body; passing it to a plain `void delegate()`
// parameter would let a non-CS context drive a context switch, so it is rejected.
import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

void withDgPlain(void delegate() dg)
{
    dg();
}

void runPlainWithLambda()
{
    withDgPlain(() {
        yieldNow@CTX_SWITCH();
    });
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_lambda_leak.d(16): Error: cannot pass `@CTX_SWITCH` lambda to non-`@CTX_SWITCH` parameter `dg`
---
*/
