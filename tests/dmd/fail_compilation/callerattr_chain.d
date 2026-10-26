// Method chaining: the glued marker `callee@mayYield(args)` binds exactly the call it
// is glued to. Gluing it to the wrong call in a chain marks a plain call (E3) and leaves
// the real @mayYield call unmarked (E2). (Compare compilable/callerattr.d, where the
// marker is glued to the correct call and needs no parentheses.)
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

struct Pipe
{
    int n;
    Pipe step1() { return Pipe(n + 1); }                                   // plain
    @mayYield Pipe step2() { yieldNow@mayYield(); return Pipe(n + 2); } // the @mayYield hop
    Pipe step3() { return Pipe(n + 3); }                                   // plain
}

@mayYield void bad()
{
    Pipe p;
    auto r = p.step1@mayYield().step2().step3();   // marker glued to step1(), not step2()
}

/*
TEST_OUTPUT:
---
fail_compilation/callerattr_chain.d(21): Error: `callerattr_chain.Pipe.step1` is not a `@mayYield` function; remove the `@mayYield` marker
fail_compilation/callerattr_chain.d(21): Error: call to `@mayYield` function `callerattr_chain.Pipe.step2` must be marked `p.step1().step2@mayYield()`
---
*/
