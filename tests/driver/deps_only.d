// Test -deps-only: emit import deps and exit before semantic/codegen.

// Basic: output goes to stdout
// RUN: %ldc -deps-only %s 2>&1 | FileCheck --check-prefix=STDOUT %s
// STDOUT: depsImport deps_only

// With -deps=file: write to file, produce no object file
// RUN: %ldc -deps-only -deps=%t.deps %s -of=%t%exe && FileCheck --check-prefix=DEPS %s < %t.deps
// RUN: not test -f %t%exe
// DEPS: depsImport deps_only

// -deps-only and -deps= together: deps file must contain import output
// RUN: %ldc -deps-only -deps=%t2.deps %s -of=%t2%exe && test -f %t2.deps && FileCheck --check-prefix=DEPS2 %s < %t2.deps
// DEPS2: depsImport deps_only

module deps_only;

import object;
