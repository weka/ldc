// The `.init` size check prints no template argument's value: druntime's
// `hasContextPointers` passes itself to `anySatisfy` while it is still being
// initialized, and evaluating it there fails with "recursive initialization".

// RUN: %ldc -c -o- %s
// RUN: not %ldc -c -o- --ctfe-max-alloc=1000 %s 2>&1 | FileCheck %s

struct Holder { ubyte[2000] buf; ~this() {} }

void moveHolder(ref Holder a, ref Holder b)
{
    import core.lifetime : move;
    move(a, b);
}

// CHECK: lifetime.d({{[0-9]+}}): Error: `ubyte[2000].init` builds a literal of at least 16000 bytes
// CHECK-NEXT: take the property from the type
// CHECK-NEXT: instantiated from here: `F!(ubyte[2000])`
// CHECK-NEXT: instantiated from here: `anySatisfy!(hasContextPointers, ubyte[2000])`
// CHECK-NEXT: instantiated from here: `hasContextPointers!(Holder)`
