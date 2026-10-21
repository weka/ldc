// `.init` of a type whose literal costs more than --ctfe-max-alloc is an error, also
// where errors are gagged, so traits built on `is(typeof(T.init))` fail loudly instead
// of silently changing their result. The literal costs one 8-byte slot per static-array
// element and per struct field, not the type's size.

// RUN: %ldc -c -o- %s
// RUN: not %ldc -c -o- --ctfe-max-alloc=1000 %s 2>&1 | FileCheck %s

// The aliases and manifest constants are resolved before the static asserts, so they
// come first here.

alias Arr = ubyte[2000];
struct Big { Arr buf; int x; }
struct Small { ubyte[100] buf; int x; }

// CHECK: ctfe_max_alloc_init.d([[@LINE+2]]): Error: `ubyte[2000].init` builds a literal of at least 16000 bytes, which exceeds `--ctfe-max-alloc=1000`
// CHECK-NEXT: take the property from the type
alias Elem = typeof(Arr.init[0]);

// `.init` through a variable.
Big g;
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `Big.init` builds a literal of at least 16016 bytes
alias G = typeof(g.init.x);

// Inside a template, the instantiation trace names the user.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `Big.init` builds a literal of at least 16016 bytes
template FieldOf(T) { alias FieldOf = typeof(T.init.x); }
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): instantiated from here: `FieldOf!(Big)`
alias F = FieldOf!Big;

// The type is below the limit (200 bytes) but its literal is not: one slot per byte.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `ubyte[200].init` builds a literal of at least 1600 bytes
alias Bytes = typeof(ubyte[200].init[0]);

// A sequence is built element by element.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `(ubyte[2000], int).init` builds a literal of at least 16016 bytes
alias Seq = typeof(typeof(Big.tupleof).init);

// A qualifier is printed once.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `const(ubyte[3000]).init` builds a literal of at least 24000 bytes
alias Const = typeof(const(ubyte[3000]).init[0]);

// Below the limit: no error. `Small` costs 16 + 800 bytes. `Grid` is 1600 bytes as a
// type, but its literal builds one row and shares it: 40 + 40 slots.
// CHECK-NOT: Small
// CHECK-NOT: [40]
alias S = typeof(Small.init.x);
alias Grid = ubyte[40][40];
alias GridElem = typeof(Grid.init[0][0]);

// Gagged contexts still report, and the result is unchanged: the constants are
// computed here, before the static asserts that test their value.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `Big.init` builds a literal of at least 16016 bytes
enum isInt = is(typeof(Big.init.x) == int);
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `Big.init` builds a literal of at least 16016 bytes
enum compiles = __traits(compiles, Big.init);

// Inside `is(...)` in a template, the trace still names the instantiation.
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `Big.init` builds a literal of at least 16016 bytes
template HasX(T) { enum HasX = is(typeof(T.init.x)); }
// CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): instantiated from here: `HasX!(Big)`
static assert(HasX!Big);

// A gagged instance that reports is kept and used by its speculative caller, as
// without the check (a discarded instance holding a sequence alias crashed here).
struct AliasBig { Arr buf; ubyte[] slice; alias slice this; }
template AliasThisOf(T)
{
    alias members = __traits(getAliasThis, T);
    // CHECK: ctfe_max_alloc_init.d([[@LINE+1]]): Error: `AliasBig.init` builds a literal of at least 16016 bytes
    alias AliasThisOf = typeof(__traits(getMember, T.init, members[0]));
}
template ArrayOf(T)
{
    static if (is(AliasThisOf!T AT))
        alias ArrayOf = AT;
    else
        alias ArrayOf = T;
}
static assert(is(ArrayOf!AliasBig == ubyte[]));

static assert(Grid.sizeof > 1000);
static assert(Grid.init.length == 40 && Grid.init[0].length == 40);
static assert(isInt);
static assert(compiles);

// CHECK-NOT: is false
