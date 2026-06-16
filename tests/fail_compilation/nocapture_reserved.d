// Tests that @nocapture is rejected where it is reserved or meaningless.

// RUN: not %ldc -o- %s 2>&1 | FileCheck %s

import core.attribute : nocapture;

// CHECK-DAG: nocapture_reserved.d([[@LINE+1]]){{.*}}: Error: `@nocapture` on functions is not supported
@nocapture void func() {}

// CHECK-DAG: nocapture_reserved.d([[@LINE+1]]){{.*}}: Error: `@nocapture` on `enum` types is not supported
@nocapture enum E { a, b }

// CHECK-DAG: nocapture_reserved.d([[@LINE+1]]){{.*}}: Error: `@nocapture` on `variable` is meaningless
@nocapture int globalVar;

// CHECK-DAG: nocapture_reserved.d([[@LINE+1]]){{.*}}: Error: `@nocapture` on `variable` is meaningless
@nocapture __gshared int gsVar;
