// Tests that @nocapture variables (and variables of a @nocapture type) cannot
// be captured by nested functions/lambdas.

// RUN: not %ldc -o- %s 2>&1 | FileCheck %s

import core.attribute : nocapture;

@nocapture struct LockGuard { void touch() {} }

// CHECK: nocapture.d([[@LINE+4]]){{.*}}: Error: variable `g` is `@nocapture` and cannot be captured by a nested function
void typeLevel()
{
    LockGuard g;
    auto bad = () { g.touch(); };
}

// CHECK: nocapture.d([[@LINE+4]]){{.*}}: Error: variable `counter` is `@nocapture` and cannot be captured by a nested function
void varLevel()
{
    @nocapture int counter;
    auto bad = () => counter + 1;
}

// CHECK: nocapture.d([[@LINE+3]]){{.*}}: Error: variable `p` is `@nocapture` and cannot be captured by a nested function
void paramLevel(@nocapture int p)
{
    auto bad = () => p + 1;
}
