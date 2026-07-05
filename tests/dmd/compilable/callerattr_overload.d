// Overloading a member function (here `opApply`) on the caller-required attribute, with
// EXPLICIT erasure at the one spot the attribute is dropped.
//
// A plain overload and a `@mayYield` overload coexist and are selected by `foreach`
// (a context-switching body picks the `@mayYield` overload) when the delegate parameter
// type is written INLINE. Both forward to a single shared `_impl` template. The
// `@mayYield` overload must therefore DROP the attribute before forwarding — and per the
// language rule "erasing a caller attribute must be explicit", that drop is written as an
// explicit cast, never an implicit conversion.
//
// See:
//   fail_compilation/callerattr_overload_alias.d  — same pattern via a type alias: overloads collide.
//   fail_compilation/callerattr_erasure.d          — implicit erasure (no cast) is rejected.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

@mayYield void yieldNow() {}

struct Chunks
{
    int[] _data;

    // Plain overload: a non-context-switching foreach body selects this; no propagation.
    // `dg` is already plain, so forwarding it needs no cast.
    int opApply(scope int delegate(ref int) dg)
    {
        return _impl(dg);
    }
    // @mayYield overload: a context-switching foreach body selects this; the @mayYield
    // on opApply propagates the attribute to the enclosing function.
    @mayYield int opApply(scope @mayYield int delegate(ref int) dg)
    {
        // Explicit erasure: cast away @mayYield so the shared `_impl` may call `dg`
        // plainly. Sound because `opApply` itself carries @mayYield, so the yield still
        // propagates to the foreach's enclosing function; the cast is the required
        // explicit act (an implicit `_impl(dg)` here would be rejected).
        return _impl(cast(int delegate(ref int)) dg);
    }
    // Shared implementation. Receives a plain delegate; its `dg(...)` call is unmarked.
    private int _impl(scope int delegate(ref int) dg)
    {
        foreach (ref x; _data) { if (auto r = dg(x)) return r; }
        return 0;
    }
}

// Plain foreach: selects the plain opApply; enclosing function stays plain.
void plainUse(ref Chunks c)
{
    foreach (ref x; c) { x += 1; }
}

// Context-switching foreach: selects the @mayYield opApply; enclosing must be @mayYield.
@mayYield void csUse(ref Chunks c)
{
    foreach (ref x; c) { yieldNow@mayYield(); }
}
