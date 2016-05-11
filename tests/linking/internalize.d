// Test internalizing (should run at -O0)

// RUN: %ldc -c -output-ll -internalize -internalize-public-api-list=keepfunc %s -of=%t.ll && FileCheck %s < %t.ll

extern(C):

// CHECK-NOT: discard
int discard() {
  return 2;
}

// CHECK: define{{.*}} @keepfunc()
int keepfunc() {
  return 1;
}

