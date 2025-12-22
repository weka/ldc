// RUN: not %ldc -c %s 2>&1 | FileCheck %s

int f(int x, int y) @__ctfe {
    return x + y;
}

int g(int x)(int y) @__ctfe {
    return x + y;
}

alias gf = g!2;

import std.stdio;

void main() {
    // CHECK: ctonly_basic.d([[@LINE+4]]): Error: cannot call @__ctfe function `ctonly_basic.f` from non-@__ctfe function `D main`
    // CHECK: ctonly_basic.d([[@LINE+3]]): Error: cannot call @__ctfe function `ctonly_basic.g!2.g` from non-@__ctfe function `D main`
    // CHECK: ctonly_basic.d([[@LINE+2]]): Error: cannot take address of CTFE-only function `f`
    // CHECK: ctonly_basic.d([[@LINE+1]]): Error: cannot take address of CTFE-only function `g`
    writeln(f(2, 4), gf(0), &f, &gf);
}
