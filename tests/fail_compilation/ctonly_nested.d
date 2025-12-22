// RUN: not %ldc -c %s 2>&1 | FileCheck %s

@__ctfe
int foo() {
    int bar() {
        return 2;
    }
    // CHECK: ctonly_nested.d([[@LINE+1]]): Error: cannot take address of CTFE-only function `bar`
    auto p = &bar; // this works because bar doesn't inherit the __ctfe attribute
    return p() + 10;
}

int main() {
    // CHECK: ctonly_nested.d([[@LINE+1]]): Error: cannot take address of CTFE-only function `foo`
    auto p = &foo;
    // CHECK: ctonly_nested.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_nested.foo` from non-@__ctfe function `D main`
    int x = foo();
    // CHECK: ctonly_nested.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_nested.bar` from non-@__ctfe function `D main`
    int y = bar(x);
    // CHECK: ctonly_nested.d([[@LINE+1]]): Error: cannot call @__ctfe function `ctonly_nested.baz` from non-@__ctfe function `D main`
    int z = baz(y);
    return x + y + z;
}

@__ctfe:
int bar(int x) {
    return x + 1;
}

int baz(int x) {
    return x + 1;
}