// Tests that @nocapture permits the cases it should: explicit parameter
// passing, static nested functions, capturing indirection rather than the
// value, and capturing an aggregate that merely contains a @nocapture field.

// RUN: %ldc -o- %s

import core.attribute : nocapture;

@nocapture struct LockGuard { void touch() {} }

void okStatic()
{
    LockGuard g;
    static int helper(ref LockGuard lg) { lg.touch(); return 0; }
    helper(g); // explicit pass, no capture
}

void okPointer()
{
    LockGuard g;
    auto p = &g;
    auto fine = () { p.touch(); }; // captures the pointer, not the value
    fine();
}

void okLambdaParam(@nocapture LockGuard lg)
{
    auto fine = (ref LockGuard x) { x.touch(); };
    fine(lg); // passed as the lambda's own parameter
}

// @nocapture does not propagate through by-value fields.
struct Wrapper { LockGuard g; }

void okContainment()
{
    Wrapper w;
    auto fine = () { w.g.touch(); }; // Wrapper itself is capturable
    fine();
}
