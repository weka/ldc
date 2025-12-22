// RUN: not %ldc -c %s 2>&1 | FileCheck %s

class C {
    int v;
    this(int v_) { v = v_; }
    int f(int x) const @__ctfe { return x + v; }
    static int g(int x) @__ctfe { return x + 2; }
}

class CtOnly {
    int v;
    this(int v_) @__ctfe { v = v_; }
    int f(int x) const { return x + v; }
    static int g(int x) { return x + 2; }
}

void main() {
    C i = new C(1);
    // CHECK: ctonly_class.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_class.C.f` from non-@__ctfe function `D main`
    int a = i.f(3);
    // CHECK: ctonly_class.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_class.C.g` from non-@__ctfe function `D main`
    int v = C.g(2);

    // CHECK: ctonly_class.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_class.CtOnly.this` from non-@__ctfe function `D main`
    auto cl = new CtOnly(5);
}
