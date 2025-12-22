// RUN: %ldc -c %s

import std.algorithm.iteration;
import std.array;

int f(int x) @__ctfe
{
    return x + 1;
}

enum a = map!f([1, 2, 3]).array;

import std.stdio;

void main() {
    writeln(a);
}
