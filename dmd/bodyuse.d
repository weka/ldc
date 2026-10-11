/**
 * Records, for `-body-use=<file>`, which parts of other modules' source a compile used: the modules
 * it analysed, the files whose function bodies it analysed or interpreted, and the files whose
 * declaration positions it read with `__traits(getLocation)`. A build system can then skip
 * recompiling an importer when only the unused bodies of an imported file change.
 *
 * Recording uses a separate malloc'd table and does no output until the compile ends, so the option
 * does not change what the compiler emits.
 */
module dmd.bodyuse;

import core.stdc.stdlib : calloc, free, qsort;
import core.stdc.string : strcmp, strlen;

import dmd.common.outbuffer;
import dmd.dmodule;
import dmd.dsymbol : PASS;
import dmd.func : FuncDeclaration;
import dmd.location;
import dmd.utils : writeFile;

enum Use : ubyte
{
    body_ = 1,     /// a function body was analysed or interpreted
    location = 2,  /// a declaration's line and column were read
}

private struct Entry
{
    const(char)* file;
    ubyte uses;
}

private __gshared const(char)* outputFile;
private __gshared Entry* table;
private __gshared size_t capacity;  // a power of two, or 0
private __gshared size_t count;

/// Turns recording on, to be written to `name` at the end of the compile.
extern (C++) void setBodyUseFile(const(char)* name) nothrow @nogc
{
    outputFile = name;
}

/// Records that the compile used the file of `loc` as `use`.
void recordUse(ref const Loc loc, Use use) nothrow @nogc
{
    if (!outputFile)
        return;
    const file = loc.filename;
    if (!file)
        return;
    if (2 * (count + 1) > capacity)
        grow();
    auto e = slot(table, capacity, file);
    if (!e.file)
    {
        e.file = file;
        count++;
    }
    e.uses |= use;
}

/// Records that the compile analysed or interpreted the body of `fd`. A body the compiler generated
/// (a postblit, destructor, `opAssign` and the like) is built from the aggregate's declarations,
/// which are not bodies, so it records nothing.
void recordBodyUse(FuncDeclaration fd)
{
    if (!fd.isGenerated())
        recordUse(fd.loc, Use.body_);
}

/// Writes the file `-body-use=` names, one line per item, sorted within each kind:
///   module <name>      a module the compile analysed
///   body <file>        a file with a function body the compile analysed or interpreted
///   location <file>    a file with a declaration whose position the compile read
/// Files are named as in the compiler's locations: a string mixin's code is `<file>-mixin-<line>`.
/// Call after code generation, which analyses the bodies it inlines from other modules.
void emitBodyUse()
{
    if (!outputFile)
        return;

    OutBuffer buf;
    foreach (m; Module.amodules)
    {
        if (m.semanticRun != PASS.initial)
        {
            buf.writestring("module ");
            buf.writestring(m.toPrettyChars());
            buf.writenl();
        }
    }

    // One file can have several pointers to its name, so merge by content.
    auto entries = cast(Entry*) calloc(count + 1, Entry.sizeof);
    size_t n = 0;
    foreach (ref e; table[0 .. capacity])
    {
        if (e.file)
            entries[n++] = e;
    }
    qsort(entries, n, Entry.sizeof, &compareFiles);
    static immutable Use[2] kinds = [Use.body_, Use.location];
    static immutable string[2] prefixes = ["body ", "location "];
    foreach (k, use; kinds)
    {
        for (size_t i = 0; i < n;)
        {
            ubyte uses = 0;
            size_t j = i;
            for (; j < n && strcmp(entries[j].file, entries[i].file) == 0; j++)
                uses |= entries[j].uses;
            if (uses & use)
            {
                buf.writestring(prefixes[k]);
                buf.writestring(entries[i].file);
                buf.writenl();
            }
            i = j;
        }
    }
    free(entries);

    writeFile(Loc.initial, outputFile[0 .. strlen(outputFile)], buf[]);
}

private:

extern (C) int compareFiles(const void* a, const void* b) nothrow @nogc
{
    return strcmp((cast(const(Entry)*) a).file, (cast(const(Entry)*) b).file);
}

Entry* slot(Entry* t, size_t cap, const(char)* file) nothrow @nogc
{
    size_t h = cast(size_t) file * cast(size_t) 0x9E3779B97F4A7C15UL;
    size_t i = (h ^ (h >> 32)) & (cap - 1);
    while (t[i].file && t[i].file != file)
        i = (i + 1) & (cap - 1);
    return &t[i];
}

void grow() nothrow @nogc
{
    const newCap = capacity ? 2 * capacity : 1024;
    auto newTable = cast(Entry*) calloc(newCap, Entry.sizeof);
    foreach (ref e; table[0 .. capacity])
    {
        if (e.file)
            *slot(newTable, newCap, e.file) = e;
    }
    free(table);
    table = newTable;
    capacity = newCap;
}
