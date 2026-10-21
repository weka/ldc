// druntime's traits and lowerings take no `.init` of the type they inspect, so they
// work under --ctfe-max-alloc on types whose `.init` literal costs more than it.
// The static asserts hold with the stock druntime too (without the limit).

// RUN: %ldc -c -o- %s
// RUN: %ldc -c -o- --ctfe-max-alloc=1000 %s

import core.internal.traits : DynamicArrayTypeOf, hasElaborateAssign, hasElaborateMove;
import core.lifetime : move, moveEmplace;

struct Plain { ubyte[2000] buf; }
struct Dtor { ubyte[2000] buf; ~this() {} }
struct PostMove { ubyte[2000] buf; void opPostMove(const ref PostMove) nothrow {} }
struct Assign { ubyte[2000] buf; void opAssign(Assign) {} }
struct ArrayAlias { ubyte[2000] buf; ubyte[] slice; alias slice this; }
struct Postblit { ubyte[2000] buf; this(this) nothrow {} }

static assert(!hasElaborateAssign!Plain);
static assert(!hasElaborateAssign!(ubyte[2000]));
static assert(hasElaborateAssign!Dtor);
static assert(hasElaborateAssign!(Dtor[2]));
static assert(hasElaborateAssign!Assign);
static assert(!hasElaborateMove!Plain);
static assert(hasElaborateMove!PostMove);
static assert(hasElaborateMove!(PostMove[2]));
static assert(is(DynamicArrayTypeOf!ArrayAlias == ubyte[]));

void movePlain(ref Plain a, ref Plain b) { move(a, b); }
void moveDtor(ref Dtor a, ref Dtor b) { move(a, b); }
void moveDtorArray(ref Dtor[2] a, ref Dtor[2] b) { move(a, b); }
void movePostMove(ref PostMove a, ref PostMove b) { move(a, b); }
void emplacePostMove(ref PostMove a, ref PostMove b) { moveEmplace(a, b); }
Dtor moveOut(ref Dtor a) { return move(a); }

bool equalArrays(ubyte[2000][] a, ubyte[2000][] b) { return a == b; }
void appendArray(ref ubyte[2000][] a, ref ubyte[2000] b) { a ~= b; }
void appendPostblit(ref Postblit[] a, ref Postblit b) { a ~= b; }
