// RUN: not %ldc -c %s 2>&1 | FileCheck %s

import std.algorithm.iteration;
import std.array;

int f(int x) @__ctfe
{
    return x + 1;
}

enum a = map!f([1, 2, 3]);

import std.stdio;

void main() {
    // That fails, because `f` is called internally.
    // CHECK: ctonly_templates.d([[@LINE+1]]): Error: cannot call @__ctfe function `std.array.array!(MapResult!(f, int[])).array` from non-@__ctfe function `D main`
    writeln(a.array);
}
