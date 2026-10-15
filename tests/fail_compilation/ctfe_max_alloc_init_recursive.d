// The `.init` size check prints no template argument's value: `hasContextPointers`
// (as druntime's was before it stopped taking `.init`) passes itself to `anySatisfy`
// while it is still being initialized, and evaluating it there fails with
// "recursive initialization".

// RUN: %ldc -c -o- %s
// RUN: not %ldc -c -o- --ctfe-max-alloc=1000 %s 2>&1 | FileCheck %s

enum bool hasContextPointers(T) = {
    static if (__traits(isStaticArray, T))
    {
        // CHECK: ctfe_max_alloc_init_recursive.d([[@LINE+1]]): Error: `ubyte[2000].init` builds a literal of at least 16000 bytes
        return hasContextPointers!(typeof(T.init[0]));
    }
    else static if (is(T == struct))
    {
        import core.internal.traits : anySatisfy;
        return __traits(isNested, T) || anySatisfy!(hasContextPointers, typeof(T.tupleof));
    }
    else return false;
} ();

struct Holder { ubyte[2000] buf; }

// CHECK-NEXT: take the property from the type
// CHECK-NEXT: instantiated from here: `F!(ubyte[2000])`
// CHECK-NEXT: instantiated from here: `anySatisfy!(hasContextPointers, ubyte[2000])`
// CHECK-NEXT: instantiated from here: `hasContextPointers!(Holder)`
enum holderHasContextPointers = hasContextPointers!Holder;
