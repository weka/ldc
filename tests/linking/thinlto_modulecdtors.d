// ThinLTO: Test that module ctors/dtors are called

// REQUIRES: atleast_llvm309
// RE QUIRES: thinlto

// RUN: %ldc -thinlto -run %s | FileCheck %s

// CHECK: ctor
// CHECK: main
// CHECK: dtor

import core.stdc.stdio;

static this()
{
    puts("ctor\n");
}

static ~this()
{
    puts("dtor\n");
}

void main() {
    puts("main\n");
}
