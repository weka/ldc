/*
PERMUTE_ARGS:
REQUIRED_ARGS: -deps-only
EXTRA_SOURCES: imports/depsOnly_basic_a.d imports/depsOnly_basic_b.d imports/depsOnly_basic_c.d
TRANSFORM_OUTPUT: remove_lines(druntime)
TEST_OUTPUT:
---
depsImport depsOnly_basic ($p:depsOnly_basic.d$) : private : imports.depsOnly_basic_a ($p:depsOnly_basic_a.d$)
depsImport depsOnly_basic ($p:depsOnly_basic.d$) : private : imports.depsOnly_basic_b ($p:depsOnly_basic_b.d$):val
depsImport depsOnly_basic ($p:depsOnly_basic.d$) : private : imports.depsOnly_basic_c ($p:depsOnly_basic_c.d$) -> renamed
---
*/
module depsOnly_basic;
import imports.depsOnly_basic_a;
import imports.depsOnly_basic_b : val;
import renamed = imports.depsOnly_basic_c;
