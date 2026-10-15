// Phobos's traits and common algorithms take no `.init` of the type they inspect, so they
// work under --ctfe-max-alloc on types whose `.init` literal costs more than it.
// The static asserts hold with the stock Phobos too (without the limit).

// RUN: %ldc -c -o- %s
// RUN: %ldc -c -o- --ctfe-max-alloc=10000 %s

import std.algorithm : each, map, maxElement, minElement, sum;
import std.array : appender;
import std.range : chunks, sequence;
import std.range.primitives : ElementType, hasSlicing, isBidirectionalRange, isForwardRange, isInputRange;
import std.traits : CommonType, ForeachType, fullyQualifiedName, hasElaborateAssign, hasNested, ifTestable,
    IntegralTypeOf, isIterable;
import std.typecons : Nullable, Rebindable, Tuple, apply, isTuple;

struct Huge { ubyte[2000] buf; int x; }
struct HugeDtor { ubyte[2000] buf; ~this() {} }
struct HugeAlias { ubyte[2000] buf; int x; alias x this; }

// A range whose own state is huge; `front` is not a `@property`.
struct HugeRange
{
    ubyte[2000] state;
    size_t i;
    bool empty() const { return i >= 3; }
    int front() const { return cast(int) i; }
    void popFront() { ++i; }
    HugeRange save() { return this; }
    int back() const { return cast(int) i; }
    void popBack() { ++i; }
    size_t length() const { return 3 - i; }
    HugeRange opSlice(size_t, size_t) { return this; }
}

static assert(isInputRange!HugeRange);
static assert(isForwardRange!HugeRange);
static assert(isBidirectionalRange!HugeRange);
static assert(hasSlicing!HugeRange);
static assert(is(ElementType!HugeRange == int));
static assert(is(ElementType!(Huge[]) == Huge));
static assert(isBidirectionalRange!(Huge[]));

static assert(is(CommonType!(Huge, Huge) == Huge));
static assert(is(CommonType!(const Huge, Huge) == const Huge));
static assert(isIterable!(Huge[2]));
static assert(isIterable!HugeRange);
static assert(is(ForeachType!(Huge[2]) == Huge));
static assert(is(ForeachType!HugeRange == int));
static assert(fullyQualifiedName!(ubyte[2000]) == "ubyte[2000]");
static assert(!hasNested!(Huge[2]));
static assert(!hasElaborateAssign!Huge);
static assert(hasElaborateAssign!(HugeDtor[2]));
static assert(!ifTestable!Huge);
static assert(is(IntegralTypeOf!HugeAlias == int));
static assert(isTuple!(Tuple!Huge));
static assert(isTuple!(const Tuple!(Huge, int[])));
static assert(!isTuple!Huge);

int mapSum(Huge[] a) { return a.map!(e => e.x).sum; }
void eachRef(ref Huge[2] a) { a.each!((ref e) => e.x++); }
void eachRange(HugeRange r) { r.each!(e => e + 1); }
int minMax(Huge[] a) { return a.minElement!(e => e.x).x + a.maxElement!(e => e.x).x; }
void appendOne(Huge[] a) { auto app = appender!(Huge[]); app.put(a[0]); app.put(a); }
int applyNullable(Nullable!Huge n) { return n.apply!(e => e.x).get(0); }
void rebind(ref const Huge a) { Rebindable!(const Huge) r = a; }
int sumRange(HugeRange r) { return r.sum; }

// `Chunks` of an infinite sliceable range declares `opSlice` returning `typeof(takeExactly(this, 0))`, which runs
// `isInputRange` on `Chunks` before its members' attributes are inferred. Unless `isInputRange` lays the struct out
// first (`R.sizeof`), `popFront` and `front` are inferred `@system` and impure.
@safe pure void chunksOfSequence()
{
    auto r = sequence!"a[0] + n * a[1]"(1, 2).chunks(2);
    r.popFront();
    auto f = r.front;
}
