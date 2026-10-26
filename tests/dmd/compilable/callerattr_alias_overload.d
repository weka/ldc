// Dual-`opApply` overloads distinguished only by the `@mayYield` caller-attribute, with the
// delegate type behind a type ALIAS. `foreach` selects the plain overload for a non-yielding body
// and the `@mayYield` overload for a context-switching body.
//
// This COMPILES because `@mayYield` is part of the delegate `TypeFunction`'s identity (its deco),
// so the two overloads are distinct even through the `Dlg` alias. Before the caller-attr became a
// type attribute this collided with "conflicts with previous declaration" (the attribute was a UDA
// the overload/type comparison ignored). See compilable/callerattr_overload.d for the inline form.
import core.attribute : callerAttr;
alias mayYield = callerAttr!"mayYield";

alias Dlg = int delegate(ref int);

struct S
{
    int opApply(scope Dlg dg)                     { return 0; }   // plain overload
    @mayYield int opApply(scope @mayYield Dlg dg) { return 0; }   // @mayYield overload (distinct)
}
