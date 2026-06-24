/**
 * Implements the `-deps` and `-makedeps` switches and the `-deps-only` fast
 * path visitor.
 *
 * The grammar of the `-deps` output is documented in `hdrgen.d`.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module dmd.deps;

import core.stdc.stdio : printf;
import core.stdc.string : strcmp;

import dmd.arraytypes;
import dmd.astcodegen;
import dmd.attrib;
import dmd.cond;
import dmd.common.outbuffer;
import dmd.declaration;
import dmd.dimport : Import;
import dmd.dmodule : Module;
import dmd.dscope;
import dmd.dsymbol;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance, TemplateMixin;
import dmd.func;
import dmd.globals : Output, global;
import dmd.hdrgen : visibilityToBuffer, stcToBuffer;
import dmd.id : Id;
import dmd.identifier : Identifier;
import dmd.location : Loc;
import dmd.mtype : Type;
import dmd.root.filename;
import dmd.statement;
import dmd.astenums : STC;
import dmd.utils : escapePath;
import dmd.visitor;

/**
 * Record an import dependency for the `-deps` output.
 *
 * Params:
 *   moduleDeps = output settings for `-deps`
 *   imp        = the import declaration
 *   imod       = the module containing the import
 */
void addImportDep(ref Output moduleDeps, Import imp, Module imod)
{
    // object self-imports itself - skip that
    // https://issues.dlang.org/show_bug.cgi?id=7547
    // don't list pseudo modules __entrypoint.d, __main.d
    // https://issues.dlang.org/show_bug.cgi?id=11117
    // https://issues.dlang.org/show_bug.cgi?id=11164
    if (moduleDeps.buffer is null || (imp.id == Id.object && imod.ident == Id.object) ||
        strcmp(imod.ident.toChars(), "__main") == 0)
        return;

    /* The grammar of the file is:
     *      ImportDeclaration
     *          ::= BasicImportDeclaration [ " : " ImportBindList ] [ " -> "
     *      ModuleAliasIdentifier ] "\n"
     *
     *      BasicImportDeclaration
     *          ::= ModuleFullyQualifiedName " (" FilePath ") : " Protection|"string"
     *              " [ " static" ] : " ModuleFullyQualifiedName " (" FilePath ")"
     *
     *      FilePath
     *          - any string with '(', ')' and '\' escaped with the '\' character
     */
    OutBuffer* ob = moduleDeps.buffer;
    if (!moduleDeps.name)
        ob.writestring("depsImport ");
    ob.writestring(imod.toPrettyChars());
    ob.writestring(" (");
    escapePath(ob, imod.srcfile.toChars());
    ob.writestring(") : ");
    // use visibility instead of sc.visibility because it couldn't be
    // resolved yet, see the comment above
    visibilityToBuffer(*ob, imp.visibility);
    ob.writeByte(' ');
    if (imp.isstatic)
    {
        stcToBuffer(*ob, STC.static_);
        ob.writeByte(' ');
    }
    ob.writestring(": ");
    foreach (pid; imp.packages)
    {
        ob.printf("%s.", pid.toChars());
    }
    ob.writestring(imp.id.toString());
    ob.writestring(" (");
    if (imp.mod)
        escapePath(ob, imp.mod.srcfile.toChars());
    else
        ob.writestring("???");
    ob.writeByte(')');
    foreach (i, name; imp.names)
    {
        if (i == 0)
            ob.writeByte(':');
        else
            ob.writeByte(',');
        Identifier _alias = imp.aliases[i];
        if (!_alias)
        {
            ob.printf("%s", name.toChars());
            _alias = name;
        }
        else
            ob.printf("%s=%s", _alias.toChars(), name.toChars());
    }
    if (imp.aliasId)
        ob.printf(" -> %s", imp.aliasId.toChars());
    ob.writenl();
}

// Stack frame used by DepsCollectVisitor to detect cycles when walking
// uninstantiated template declaration members.
private struct TDFrame
{
    TemplateDeclaration td;
    TDFrame* prev;
}

// Lightweight AST visitor for -deps-only.
// Walks the parsed AST collecting imports, evaluating conditionals only where
// needed, without running full semantic analysis.
extern(C++) class DepsCollectVisitor : Visitor
{
    alias visit = typeof(super).visit;

    Scope* sc;
    TDFrame* tdStack = null;  // cycle guard for visit(TemplateMixin)
    bool inMixinBody = false; // true while walking uninstantiated mixin template members

    extern(D) this(Scope* sc)
    {
        this.sc = sc;
    }

    // Temporarily lift the depsOnly fast-paths so that templates triggered by
    // condition evaluation can complete their semantic analysis.
    extern(D) private bool disableDepsOnly()
    {
        bool old = global.params.depsOnly;
        global.params.depsOnly = false;
        return old;
    }

    // Catch-alls: skip everything we don't specifically handle
    override void visit(Dsymbol d) {}
    override void visit(ASTCodegen.Parameter p) {}
    override void visit(Statement s) {}
    override void visit(ASTCodegen.Type t) {}
    override void visit(ASTCodegen.Expression e) {}
    override void visit(ASTCodegen.TemplateParameter tp) {}
    override void visit(ASTCodegen.Condition c) {}
    override void visit(ASTCodegen.Initializer i) {}

    // Module: recurse into members using existing scope
    override void visit(Module m)
    {
        if (!m.members) return;
        foreach (s; *m.members)
        {
            if (s) s.accept(this);
        }
    }

    // ScopeDsymbol: recurse into members (catches class, struct, union, etc.)
    override void visit(ScopeDsymbol sd)
    {
        if (!sd.members) return;
        if (sd.isTemplateDeclaration())
            return;
        foreach (s; *sd.members)
            s.accept(this);
    }

    // TemplateMixin: walk the template's uninstantiated members to capture any
    // import declarations inside the mixin body.
    //
    // Cycle guard: mixin templates can reference themselves (directly or via
    // mutual recursion). tdStack is a singly-linked list of stack frames -
    // one per template declaration being visited - so we can detect and break
    // cycles in O(depth) time without any heap allocation.
    override void visit(TemplateMixin tm)
    {
        if (!tm.tempdecl)
        {
            for (size_t i = 0; i < Module.amodules.length; i++)
            {
                auto m = Module.amodules[i];
                if (!m.members) continue;
                foreach (s; *m.members)
                {
                    if (auto td = s.isTemplateDeclaration())
                    {
                        if (td.ident == tm.name)
                        {
                            tm.tempdecl = td;
                            goto Lfound;
                        }
                    }
                }
            }
            Lfound: {}
        }
        if (auto td = tm.tempdecl ? tm.tempdecl.isTemplateDeclaration() : null)
        {
            // Cycle check: skip if we're already walking this template's body.
            for (auto f = tdStack; f; f = f.prev)
                if (f.td is td) return;

            auto frame = TDFrame(td, tdStack);
            tdStack = &frame;
            scope(exit) tdStack = frame.prev;

            if (td.members)
            {
                auto savedSc = sc;
                bool savedInMixinBody = inMixinBody;
                if (td._scope) sc = td._scope;
                inMixinBody = true;
                foreach (s; *td.members)
                    if (s) s.accept(this);
                sc = savedSc;
                inMixinBody = savedInMixinBody;
            }
        }
    }

    // FuncDeclaration: walk function body to catch local imports.
    // Skip uninstantiated template function bodies to match -deps behavior.
    override void visit(FuncDeclaration fd)
    {
        if (!fd.fbody) return;
        auto p = fd.toParent();
        if ((p && p.isTemplateDeclaration()) ||
            (fd.overnext && fd.overnext.isTemplateDeclaration()))
            return;
        fd.fbody.accept(this);
    }

    // AliasDeclaration: skip.
    // We intentionally don't recurse into aliassym or template declaration
    // members here. Walking template declaration members with unbound type
    // parameters causes infinite recursion for self-referential templates
    // (e.g. AliasSeq's eponymous alias loops back to itself). All loaded
    // modules are iterated in main.d, so any imports reachable through alias
    // chains are found via their declaring modules' own member walks.
    override void visit(AliasDeclaration ad) {}

    override void visit(UnitTestDeclaration utd)
    {
        if (utd.fbody)
            utd.fbody.accept(this);
    }

    // Import: register the dependency
    override void visit(Import imp)
    {
        import dmd.dsymbolsem : load, importAll;

        // Module-level imports have _scope set during importAll's setScope pass.
        // Local imports (_scope == null, inside function bodies) must NOT have
        // semanticRun set here -- setting it would block dsymbolSemantic(Import)
        // from calling imp.mod.dsymbolSemantic(null) later, which is needed to
        // evaluate module-level mixins (e.g. mixin(versionIdCodeGen())).
        bool isModuleLevel = imp._scope !is null;

        if (!isModuleLevel && imp.mod !is null)
            return;  // local import already loaded on a prior visit

        if (!imp.mod)
        {
            if (load(imp, sc))
            {
                if (isModuleLevel)
                {
                    for (size_t i; i < imp.aliasdecls.length; i++)
                        imp.aliasdecls[i].type = Type.terror;
                }
                addImportDep(global.params.moduleDeps, imp, sc._module);
                return;
            }
            if (imp.mod)
                imp.mod.importAll(null);
        }

        // Resolve selective import alias decls directly from the loaded module's
        // symbol table (populated by importAll). A direct symtab lookup avoids
        // triggering dsymbolSemantic, while still marking each alias as resolved
        // so that aliasSemantic's Ungag trick does not fire in template contexts
        // from disableDepsOnly() evaluation.
        if (isModuleLevel && imp.mod && imp.mod.symtab)
        {
            for (size_t i = 0; i < imp.aliasdecls.length; i++)
            {
                auto ad = imp.aliasdecls[i];
                if (ad.semanticRun >= PASS.semanticdone) continue;
                auto sym = imp.mod.symtab.lookup(imp.names[i]);
                if (sym)
                    ad.aliassym = sym;
                else
                    ad.type = Type.terror;
                ad.semanticRun = PASS.semanticdone;
            }
        }
        addImportDep(global.params.moduleDeps, imp, sc._module);
    }

    // AttribDeclaration: pass through and recurse into decl
    override void visit(AttribDeclaration ad)
    {
        if (ad.errors || !ad.decl) return;
        foreach (s; *ad.decl)
            s.accept(this);
    }

    // ConditionalDeclaration (version/debug): evaluate condition
    override void visit(ConditionalDeclaration cdc)
    {
        if (cdc.errors || !cdc.condition) return;
        Scope* csc = cdc._scope ? cdc._scope : sc;
        // Suppress output during condition evaluation
        auto savedBuf = global.params.moduleDeps.buffer;
        global.params.moduleDeps.buffer = null;
        bool active = cdc.condition.include(csc) != 0;
        global.params.moduleDeps.buffer = savedBuf;
        Dsymbols* branch = active ? cdc.decl : cdc.elsedecl;
        if (branch)
        {
            Scope* ns = cdc.newScope(csc);
            foreach (s; *branch)
                s.accept(this);
            if (ns != csc)
                ns.pop();
        }
    }

    // StaticIfDeclaration: at module/aggregate scope, evaluate the condition under
    // full semantic and walk only the active branch. Inside an uninstantiated mixin
    // template body, template parameters are undefined, so we conservatively walk
    // both branches to avoid triggering Ungag via disableDepsOnly.
    override void visit(StaticIfDeclaration sif)
    {
        if (sif.errors || sif.onStack) return;
        sif.onStack = true;
        scope(exit) sif.onStack = false;

        Scope* csc = sif._scope ? sif._scope : sc;

        if (inMixinBody)
        {
            // Inside an uninstantiated template body: can't evaluate conditions
            // that may reference template parameters. Walk both branches to avoid
            // missing any imports.
            if (sif.decl)
            {
                Scope* ns = sif.newScope(csc);
                foreach (s; *sif.decl)
                    s.accept(this);
                if (ns != csc) ns.pop();
            }
            if (sif.elsedecl)
            {
                Scope* ns = sif.newScope(csc);
                foreach (s; *sif.elsedecl)
                    s.accept(this);
                if (ns != csc) ns.pop();
            }
            return;
        }

        // At module/aggregate scope: evaluate condition with full semantic.
        // Null the deps buffer so that dsymbolSemantic(Import) calls within the
        // disableDepsOnly chain don't double-record deps.
        auto savedBuf = global.params.moduleDeps.buffer;
        global.params.moduleDeps.buffer = null;
        auto savedDepsOnly = disableDepsOnly();
        global.gag++;
        uint savedErrors = global.errors;

        bool active = sif.condition.include(csc) != 0;

        global.errors = savedErrors;
        global.gag--;
        global.params.depsOnly = savedDepsOnly;
        global.params.moduleDeps.buffer = savedBuf;

        Dsymbols* branch = active ? sif.decl : sif.elsedecl;
        if (branch)
        {
            Scope* ns = sif.newScope(csc);
            foreach (s; *branch)
                s.accept(this);
            if (ns != csc)
                ns.pop();
        }
    }

    // StaticForeachDeclaration: walk already-expanded body only.
    //
    // Calling sfd.include() under depsOnly=true is unsafe:
    //   - Template aggregates (e.g. FieldNameTuple!T) return void because the
    //     fast-path leaves their eponymous aliases unresolved.
    //   - lowerNonArrayAggregate then creates CTFE-based AST transformations
    //     that cascade into further template instantiations and alias
    //     resolutions, causing infinite recursion and stack overflow.
    //   - Using disableDepsOnly() is equally unsafe: full semantic cascades
    //     transitively into modules that have unevaluated mixins (e.g.
    //     mixin(udaDecls())), triggering Ungag inside template contexts and
    //     making errors visible despite gagging.
    //
    // Instead we only visit sfd.cache if it was already populated by a prior
    // full-semantic pass. Imports inside static-foreach bodies are missed in
    // depsOnly mode, which is an accepted approximation.
    override void visit(StaticForeachDeclaration sfd)
    {
        if (sfd.errors || sfd.onStack) return;
        if (sfd.cache)
        {
            foreach (s; *sfd.cache)
                s.accept(this);
        }
    }

    // PragmaDeclaration: recurse into decl
    override void visit(PragmaDeclaration pd)
    {
        if (pd.decl)
        {
            foreach (s; *pd.decl)
                s.accept(this);
        }
    }

    // --- Statement visitors for function-body import capture ---

    override void visit(ImportStatement s)
    {
        if (s.imports)
        {
            foreach (imp; *s.imports)
                if (imp) imp.accept(this);
        }
    }

    override void visit(CompoundStatement s)
    {
        if (s.statements)
        {
            foreach (st; *s.statements)
                if (st) st.accept(this);
        }
    }

    override void visit(ScopeStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    override void visit(IfStatement s)
    {
        if (s.ifbody) s.ifbody.accept(this);
        if (s.elsebody) s.elsebody.accept(this);
    }

    override void visit(WhileStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(DoStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(ForStatement s)
    {
        if (s.init) s.init.accept(this);
        if (s._body) s._body.accept(this);
    }

    override void visit(ForeachStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(ForeachRangeStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(SwitchStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(CaseStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    override void visit(CaseRangeStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    override void visit(DefaultStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    override void visit(WithStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(TryCatchStatement s)
    {
        if (s._body) s._body.accept(this);
        if (s.catches)
        {
            foreach (c; *s.catches)
                if (c.handler) c.handler.accept(this);
        }
    }

    override void visit(TryFinallyStatement s)
    {
        if (s._body) s._body.accept(this);
        if (s.finalbody) s.finalbody.accept(this);
    }

    override void visit(SynchronizedStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(LabelStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    override void visit(PragmaStatement s)
    {
        if (s._body) s._body.accept(this);
    }

    override void visit(ScopeGuardStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }

    // ConditionalStatement: evaluate condition, walk only the active branch.
    // Gag errors during evaluation: static if conditions inside function bodies
    // may reference local symbols not in our module scope (e.g. struct members,
    // foreach loop variables). We suppress the resulting undefined-identifier
    // errors and accept that the wrong branch may occasionally be walked.
    override void visit(ConditionalStatement s)
    {
        global.gag++;
        uint savedErrors = global.errors;
        bool active = s.condition.include(sc) != 0;
        global.errors = savedErrors;
        global.gag--;
        Statement branch = active ? s.ifbody : s.elsebody;
        if (branch) branch.accept(this);
    }

    override void visit(StaticForeachStatement s)
    {
        if (s.sfe.aggrfe && s.sfe.aggrfe._body)
            s.sfe.aggrfe._body.accept(this);
        if (s.sfe.rangefe && s.sfe.rangefe._body)
            s.sfe.rangefe._body.accept(this);
    }

    override void visit(UnrolledLoopStatement s)
    {
        if (s.statements)
        {
            foreach (st; *s.statements)
                if (st) st.accept(this);
        }
    }

    override void visit(ForwardingStatement s)
    {
        if (s.statement) s.statement.accept(this);
    }
}
