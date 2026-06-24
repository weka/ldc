/*
PERMUTE_ARGS:
REQUIRED_ARGS: -deps-only
EXTRA_SOURCES: imports/depsOnly_trans_a.d imports/depsOnly_trans_b.d imports/depsOnly_trans_c.d
TRANSFORM_OUTPUT: remove_lines(druntime)
TEST_OUTPUT:
---
depsImport depsOnly_transitive ($p:depsOnly_transitive.d$) : private : imports.depsOnly_trans_a ($p:depsOnly_trans_a.d$)
depsImport imports.depsOnly_trans_a ($p:depsOnly_trans_a.d$) : private : imports.depsOnly_trans_b ($p:depsOnly_trans_b.d$)
depsImport imports.depsOnly_trans_b ($p:depsOnly_trans_b.d$) : private : imports.depsOnly_trans_c ($p:depsOnly_trans_c.d$)
---
*/
module depsOnly_transitive;
import imports.depsOnly_trans_a;
