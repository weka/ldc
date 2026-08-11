// AArch64 fiber-switch GC scan regression test.
//
// On AArch64, d8-d15 are callee-saved, so the compiler may keep a live
// GC pointer in one of them (e.g. fmov d8, x0) across a suspension
// point.  fiber_switchContext used to report sp + 9*8 as the stack top,
// hiding the saved lr and d8-d15 from the GC scan - a pointer whose
// only copy sat in a saved FP register could be collected while the
// fiber was suspended.
//
// The test parks the sole reference to a canary object in d8 (all other
// copies XOR-obfuscated), yields, forces collections plus heap churn
// from the main context, then resumes and checks the canary survived.

version (LDC) version (AArch64) version = TestAArch64GcScan;

version (TestAArch64GcScan)
{
    import core.memory : GC;
    import core.thread : Fiber;
    import ldc.llvmasm : __asm;

    enum size_t MAGIC = 0xDEAD_BEEF_CAFE_F00D;
    enum size_t KEY = 0xA5A5_A5A5_A5A5_A5A5;
    enum PAYLOAD_WORDS = (4 * 1024 * 1024) / size_t.sizeof;

    class Canary
    {
        __gshared bool collected;
        size_t[] payload;
        ~this() { collected = true; }
    }

    // Returns the canary address XOR-obfuscated so the raw pointer has
    // no GC-visible copy outside the fiber's saved d8.
    size_t makeCanary()
    {
        pragma(inline, false);
        auto c = new Canary;
        c.payload = new size_t[PAYLOAD_WORDS];
        c.payload[] = MAGIC;
        return (cast(size_t) cast(void*) c) ^ KEY;
    }

    // Zero the stack below the current frame to wipe stale spills of
    // the raw pointer left behind by makeCanary.
    void scrubStack()
    {
        pragma(inline, false);
        size_t[1024] z = 0;
        __asm("", "r,~{memory}", z.ptr);
    }

    // Clear scratch registers that might still hold the raw pointer.
    void scrubRegs()
    {
        pragma(inline, false);
        __asm("mov x9, xzr
               mov x10, xzr
               mov x11, xzr
               mov x12, xzr
               mov x13, xzr
               mov x14, xzr
               mov x15, xzr",
              "~{x9},~{x10},~{x11},~{x12},~{x13},~{x14},~{x15}");
    }

    __gshared bool sawCollected;
    __gshared bool payloadIntact;

    void fiberFunc()
    {
        size_t obf = makeCanary();

        // Deobfuscate straight into d8; x9 is scrubbed so the raw
        // pointer exists nowhere else.
        __asm("eor x9, $0, $1
               fmov d8, x9
               mov x9, xzr",
              "r,r,~{x9},~{d8}", obf, KEY);
        obf = 0;
        scrubStack();

        Fiber.yield();

        auto c = cast(Canary) cast(void*) __asm!size_t("fmov $0, d8", "=r");
        sawCollected = Canary.collected;
        if (!sawCollected)
            payloadIntact = c.payload.length == PAYLOAD_WORDS
                && c.payload[0] == MAGIC && c.payload[$ - 1] == MAGIC;
    }

    void main()
    {
        auto fib = new Fiber(&fiberFunc);
        fib.call();

        // The canary now lives only in the suspended fiber's saved d8.
        scrubRegs();
        GC.collect();
        foreach (i; 0 .. 8)
        {
            auto junk = new size_t[PAYLOAD_WORDS];
            junk[] = 0x0101_0101_0101_0101;
            __asm("", "r,~{memory}", junk.ptr);
        }
        GC.collect();

        fib.call();
        assert(!sawCollected, "canary collected: saved d8 was hidden from the GC scan");
        assert(payloadIntact, "canary payload corrupted");
    }
}
else
{
    void main() {} // only meaningful on AArch64 with LDC
}
