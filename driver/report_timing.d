//===-- driver/report_timing.d - General LLVM codegen helpers ----------*- D -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
//
//===----------------------------------------------------------------------===//

module driver.report_timing;

import ddmd.globals;

import std.string;
import std.stdio;
import std.datetime;

StopWatch sw;

static this()
{
    sw.start();
}

static ulong scopeCounter;

auto printTimeSpentInScope(Args...)(string name, lazy Args args)
{
    import std.format;
    struct RAII(Args...)
    {
        string str;
        StopWatch stopwatch;

        this (string name, lazy Args args) {
            if (global.params.verboseCompileTimings) {
                str = format(name, args);
                //stdout.writeln(str);
                scopeCounter++;
                stopwatch.start();
            }
        }
        ~this() {
            if (global.params.verboseCompileTimings) {
                auto msecs = stopwatch.peek().msecs;
                scopeCounter--;
                if (msecs < 20)
                    return;
                stdout.writeln(scopeCounter+1, ", ", str, ", ", msecs, " ms");
            }
        }
    }

    return RAII!(Args)(name, args);
}


void printCurrentTime(Args...)(string name, Args args)
{
    if (global.params.verboseCompileTimings)
    {
        printf(name.toStringz(), args);
        stdout.writeln(": ", sw.peek().msecs, " ms");
    }
}

extern (C++, timing)
{

    void printCurrentTime(const(char)* name)
    {
        if (global.params.verboseCompileTimings)
        {
            stdout.writef("%s");
  //          stdout.writeln(": ", sw.peek());
        }
    }

    void startTime(const(char)* name)
    {
        if (global.params.verboseCompileTimings)
        {
            stdout.writefln("start %s", name);
        }
    }

    void endTime(const(char)* name)
    {
        if (global.params.verboseCompileTimings)
        {
            stdout.writefln("end   %s", name);
        }
    }

}
