/**
 * Compile-time checks associated with the @nocapture attribute.
 *
 * A `@nocapture` variable (or any variable of a `@nocapture` type) may not be
 * captured by a nested function or lambda; it must be passed explicitly. See
 * `core.attribute.nocapture` for the user-facing description.
 *
 * Copyright: Copyright (C) 2024 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/nocapture.d, _nocapture.d)
 */

module dmd.nocapture;

import dmd.declaration;
import dmd.dscope;
import dmd.dsymbol;
import dmd.errors;
import dmd.expression;
import dmd.identifier;

/**
 * Returns: true if the given local variable may not be captured by a nested
 * function, either because it is itself declared `@nocapture` or because its
 * type is a `@nocapture` aggregate.
 *
 * Params:
 *   v  = the captured variable
 *   sc = scope in which the capture occurs
 */
bool isNoCapture(VarDeclaration v, Scope* sc)
{
    import dmd.typesem : toDsymbol;

    // variable-level: the declaration itself is marked
    if (hasNoCaptureAttribute(v, sc))
        return true;

    // type-level: the variable's own (by-value) type is a marked aggregate.
    // Deliberately not transitive: fields and indirection (T*, ref T, T[])
    // are not covered.
    if (v.type)
    {
        if (auto sym = v.type.toDsymbol(sc))
        {
            if (auto ad = sym.isAggregateDeclaration())
                return hasNoCaptureAttribute(ad, sc);
        }
    }

    return false;
}

/**
 * Called from a symbol's semantic to reject `@nocapture` where it is reserved
 * or meaningless. Emits an error in those cases.
 *
 * Allowed: `struct`/`union`/`class` declarations and stack-local variables
 * (including function parameters, which can be captured).
 * Rejected: functions, `enum`s, and variables that are never captured
 * (globals and `__gshared`/TLS/`static` storage).
 *
 * Params:
 *   sym = symbol to check
 */
void checkNoCaptureReserved(Dsymbol sym)
{
    import dmd.attrib : foreachUdaNoSemantic;
    import dmd.id : Id;

    // Can't use foreachUda (and by extension hasNoCaptureAttribute) while
    // semantic analysis of `sym` is still in progress
    foreachUdaNoSemantic(sym, (exp) {
        if (!isNoCaptureAttribute(exp))
            return 0; // continue

        if (sym.isFuncDeclaration())
        {
            error(sym.loc, "`@%s` on functions is not supported",
                Id.udaNoCapture.toChars());
            sym.errors = true;
        }
        else if (sym.isEnumDeclaration())
        {
            error(sym.loc, "`@%s` on `enum` types is not supported",
                Id.udaNoCapture.toChars());
            sym.errors = true;
        }
        else if (auto vd = sym.isVarDeclaration())
        {
            // Globals/__gshared/TLS/static storage are never captured (see the
            // isDataseg() guard in VarDeclaration.checkNestedReference), so the
            // attribute is meaningless there. Parameters, however, can be
            // captured, so they are allowed and enforced.
            if (vd.isDataseg())
            {
                error(sym.loc, "`@%s` on `%s` is meaningless; only stack-local variables (and parameters) can be captured",
                    Id.udaNoCapture.toChars(), vd.kind());
                sym.errors = true;
            }
        }
        return 0; // continue
    });
}

/**
 * Returns: true if the given symbol has the `@nocapture` attribute.
 */
private bool hasNoCaptureAttribute(Dsymbol sym, Scope* sc)
{
    import dmd.attrib : foreachUda;

    bool result = false;

    foreachUda(sym, sc, (Expression uda) {
        if (isNoCaptureAttribute(uda))
        {
            result = true;
            return 1; // break
        }
        return 0; // continue
    });

    return result;
}

/**
 * Returns: true if the given expression is core.attribute.nocapture.
 */
private bool isNoCaptureAttribute(Expression e)
{
    import dmd.attrib : isEnumAttribute;
    import dmd.id : Id;
    return isEnumAttribute(e, Id.udaNoCapture);
}
