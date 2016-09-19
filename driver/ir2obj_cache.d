//===-- driver/ir2obj_cache.d -------------------------------------*- D -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//

module driver.ir2obj_cache;

import ddmd.arraytypes;
import ddmd.dmodule;
import ddmd.errors;
import ddmd.globals;
import ddmd.root.filename;

import std.digest.md;

extern (C++, ir2obj) void recoverObjectFile(const(char)* cacheFile, size_t cacheFileLen,
    const(char)* objectFile, size_t objectFileLen);

struct ManifestDependency
{
    string filename;
    string hash;
}

string getManifestFileName(const(char)[] hash)
{
    import std.path;
    import std.string;
    import core.stdc.string;
    import std.conv;

    string cachePath = to!string(global.params.useCompileCache);
    return buildNormalizedPath(expandTilde(cachePath), "manifest_" ~ hash);
}

extern (C++) void cacheManifest(const(char)* hash, const(char)* cacheObjFile)
{
    import std.stdio;
    import std.string;
    import std.path;

    auto filename = getManifestFileName(fromStringz(hash));
    auto f = File(filename, "w");

    f.writeln("Cached object file:");
    f.writeln(fromStringz(cacheObjFile));

    f.writeln("Non-existant paths:");
    foreach (fname; nonExistantPaths)
    {
        f.writeln(fname);
    }

    f.writeln("Imported:");
    foreach (i, fname; Module.allTextImports)
    {
        f.writeln(fromStringz(fname));
        f.writeln(fromStringz(Module.allTextImportsHash[i]));
    }
    foreach (m; Module.amodules)
    {
        if (!m.isRoot)
        {
            auto fname = fromStringz(m.srcfile.toChars());
            f.writeln(fname.asAbsolutePath);
            f.writeln(fromStringz(m.srcfile.hashToChars()));
        }
    }

    f.close();
}

void touchFile(string filename)
{
    import std.stdio : File;

    auto f = File(filename, "r+");
    f.close();
}

// Return true when successful
extern(C++) bool attemptRecoverFromCache(Modules *modules, const(char)* outputObjFile)
{
    static import std.file;
    import std.string;
    import core.stdc.string;

    string hash = calculateModulesHash(*modules);
    global.params.compileHash = toStringz(hash);

    string cacheObjFile;
    ManifestDependency[] deps;
    string[] nonexistant;
    if (!readManifest(hash, cacheObjFile, deps, nonexistant))
    {
        import std.stdio;
        writeln("No manifest found for ", outputObjFile[0..strlen(outputObjFile)]);

        import core.runtime;
        auto args = Runtime.cArgs();
        for (size_t i = 0; i < args.argc; i++)
        {
            writeln("    ", fromStringz(args.argv[i]));
        }
    }

    // The cached file may have been removed (e.g. by cache pruning).
    if (!std.file.exists(cacheObjFile))
        return false;

    foreach (fname; nonexistant)
    {
        if (std.file.exists(fname))
        {
            import std.stdio;
            writeln("New existing file ", fname);
            return false;
        }
    }

    if (!checkManifestDependencies(deps))
        return false;

    // It all checks out! Let's recover the cached file and be happy :-)
    recoverObjectFile(cacheObjFile.ptr, cacheObjFile.length, outputObjFile, strlen(outputObjFile));
    return true;
}

string calculateModulesHash(ref Modules modules)
{
    import std.string;
    import std.stdio;
    import std.file;

    MD5 md5;
    md5.start();

    // First add the compiler version to the hash
    md5.put(cast(const(ubyte)[]) fromStringz(global.ldc_version));
    md5.put(cast(const(ubyte)[]) fromStringz(global._version));
    md5.put(cast(const(ubyte)[]) fromStringz(global.llvm_version));

    addCommandlineToHash(md5);

    // The current directory is also an input (import lookup).
    md5.put(cast(const(ubyte)[]) getcwd());

    // Add the date and/or time as compile "input" in case the Lexer needed it.
    if (global.params.dateUsedByLexer) {
        writeln("Used DATE");
        md5.put(cast(const(ubyte)[]) fromStringz(global.params.dateUsedByLexer));
    }
    if (global.params.timeUsedByLexer) {
        writeln("Used TIME");
        md5.put(cast(const(ubyte)[]) fromStringz(global.params.timeUsedByLexer));
    }

    foreach (ref m; modules)
    {
        md5.put(m.srcfile.buffer[0 .. m.srcfile.len]);
        // Also add the module source filenames to the hash (because it is an input to the compiler: __FILE__)
        md5.put(cast(const(ubyte)[]) fromStringz(m.srcfile.name.toChars()));
    }

    // Also add bitcode files that were passed on the cmdline
    /* 2.070 doesn't support bitcodefiles
    foreach (fname; *global.params.bitcodeFiles)
    {
        import std.exception;
        import std.stdio;

        try
        {
            auto f = File(fromStringz(fname), "rb");
            foreach (buffer; f.byChunk(4096))
                md5.put(buffer);
        }
        catch (ErrnoException)
        {
            error(Loc(), "Error when loading LLVM bitcode file: %s", fname);
            fatal();
        }
    }
    */

    auto hash = md5.finish();
    return toHexString!(LetterCase.lower)(hash).dup;
}

private void addCommandlineToHash(ref MD5 md5)
{
    import core.runtime;
    import std.string;

    // Add _all_ commandline flags to the hash, except the ones that are proven to not matter.
    // TODO: make the hash independent of things that don't matter:
    //       - order of cmdline flags (e.g. "-g -c" == "-c -g")
    //       - and more...
    auto args = Runtime.cArgs();
    for (size_t i = 0; i < args.argc; i++)
    {
        md5.put(cast(const(ubyte)[]) fromStringz(args.argv[i]));
    }
}

bool checkManifestDependencies(ref ManifestDependency[] deps)
{
    foreach (ref d; deps)
    {
        if (!checkManifestDependency(d))
            return false;
    }

    return true;
}

// true if we have a match
bool checkManifestDependency(ref ManifestDependency dep)
{
    import std.digest.md;
    import std.file;
    import std.stdio;
    import std.string;

    if (!exists(dep.filename))
        return false;

    auto f = File(dep.filename, "rb");
    auto md5 = md5Of(f.byChunk(4096));
    bool match = toHexString!(LetterCase.lower)(md5) == dep.hash;

if (!match)
    writeln("No match: ", dep.filename);

    return match;
}

bool readManifest(string hash, ref string cacheObjFile, ref ManifestDependency[] deps, ref string[] nonexistant)
{
    import std.file;
    import std.stdio;
    import std.string;
    import std.array;
    import std.conv;

    auto filename = getManifestFileName(hash);
    if (!exists(filename))
        return false;
    auto f = File(filename, "r");
    scope(exit) f.close();

    char[] buf;
    f.readln(buf);
    if (buf != "Cached object file:\n")
    {
        warning(Loc(), "Corrupt manifest (%s) 1", filename.toStringz());
        return false;
    }

    f.readf("%s\n", &cacheObjFile);
    if (cacheObjFile.empty)
    {
        warning(Loc(), "Corrupt manifest (%s) 2", filename.toStringz());
        return false;
    }

    f.readln(buf);
    if (buf != "Non-existant paths:\n")
    {
        warning(Loc(), "Corrupt manifest (%s) 3", filename.toStringz());
        return false;
    }

    string fname;
    while (!f.eof)
    {
        auto status = f.readf("%s\n", &fname);
        if (status != 1)
            break;
        if (fname == "Imported:")
            break;

        nonexistant ~= fname;
    }

    if (fname != "Imported:")
    {
        warning(Loc(), "Corrupt manifest (%s) 4", filename.toStringz());
        return false;
    }

    while (!f.eof)
    {
        ManifestDependency dep;
        auto status = f.readf("%s\n%s\n", &dep.filename, &dep.hash);
        if (status != 2)
            break;

        deps ~= dep;
    }

    return true;
}
