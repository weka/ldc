// Method chaining: the glued marker `callee@CTX_SWITCH(args)` binds exactly the call it
// is glued to. Gluing it to the wrong call in a chain marks a plain call (E3) and leaves
// the real @CTX_SWITCH call unmarked (E2). (Compare compilable/callerattr.d, where the
// marker is glued to the correct call and needs no parentheses.)
import core.attribute : callerAttr;
alias CTX_SWITCH = callerAttr!"CTX_SWITCH";

@CTX_SWITCH void yieldNow() {}

struct Pipe
{
    int n;
    Pipe step1() { return Pipe(n + 1); }                                   // plain
    @CTX_SWITCH Pipe step2() { yieldNow@CTX_SWITCH(); return Pipe(n + 2); } // the @CTX_SWITCH hop
    Pipe step3() { return Pipe(n + 3); }                                   // plain
}

@CTX_SWITCH void bad()
{
    Pipe p;
    auto r = p.step1@CTX_SWITCH().step2().step3();   // marker glued to step1(), not step2()
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_chain.d(21): Error: `callerattr_chain.Pipe.step1` is not a `@CTX_SWITCH` function; remove the `@CTX_SWITCH` marker
fail_compilation/callerattr_chain.d(21): Error: call to `@CTX_SWITCH` function `callerattr_chain.Pipe.step2` must be marked `p.step1().step2@CTX_SWITCH()`
---
*/
