/* Do a smoke test of the C Standard headers.
 * Many platforms do not support all the C Standard headers.
 * DISABLED: LDC // FIXME: needs preprocessor
 */

#include <assert.h>

#ifndef __DMC__ // D:\a\1\s\tools\dm\include\complex.h(105): Deprecation: use of complex type `cdouble` is deprecated, use `std.complex.Complex!(double)` instead
#ifndef __FreeBSD__ // defines _COMPLEX_I with use of `i` postfix
#include <complex.h>
#endif
#endif

#include <ctype.h>
#include <errno.h>

#ifndef _MSC_VER // C:\Program Files (x86)\Windows Kits\10\include\10.0.22621.0\ucrt\fenv.h(68): Error: variable `stdcheaders._Fenv1` extern symbols cannot have initializers
#ifndef __FreeBSD__ // cannot turn off __GNUCLIKE_ASM in machine/ieeefp.h
#include <fenv.h>
#endif
#endif

#include <float.h>
#include <inttypes.h>
#include <iso646.h>
#include <limits.h>
#include <locale.h>

#ifndef __APPLE__ // /Applications/Xcode-14.2.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/tgmath.h(39): Error: named parameter required before `...`
#include <math.h>
#endif

#ifndef _MSC_VER // setjmp.h(51): Error: missing tag `identifier` after `struct
#include <setjmp.h>
#endif

#include <signal.h>

#ifndef __DMC__ // no stdalign.h
#include <stdalign.h>
#endif

#include <stdarg.h>

#ifndef __DMC__ // no stdatomic.h
#ifndef __linux__
#ifndef _MSC_VER
#ifndef __APPLE__ // /Applications/Xcode-14.2.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/14.0.0/include/stdatomic.h(80): Error: type-specifier is missing
#ifndef __FreeBSD__ // /stdatomic.h(162): Error: found `volatile` when expecting `{`
#include <stdatomic.h>
#endif
#endif
#endif
#endif
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifndef _MSC_VER // ucrt\corecrt_malloc.h(58): Error: extended-decl-modifier expected
#include <stdlib.h>
#endif

#ifndef __DMC__ // no stdnoreturn.h
#include <stdnoreturn.h>
#endif

#include <string.h>

#ifndef __DMC__ // no tgmath.h
#ifndef _MSC_VER // C:\Program Files (x86)\Windows Kits\10\include\10.0.22621.0\ucrt\tgmath.h(33): Error: no type for declarator before `)`
#ifndef __APPLE__ // /Applications/Xcode-14.2.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/tgmath.h(39): Error: named parameter required before `...`
#ifndef __FreeBSD__  // #includes complex.h
#include <tgmath.h>
#endif
#endif
#endif
#endif

#ifndef __DMC__
#ifndef __linux__
#ifndef __APPLE__
#ifndef _MSC_VER
#include <threads.h>
#endif
#endif
#endif
#endif

#include <time.h>

#ifndef __DMC__ // no uchar.h
#ifndef __APPLE__ // no uchar.h
#include <uchar.h>
#endif
#endif

#include <wchar.h>

#ifndef __DMC__ // wctype.h(102): Error: unterminated string constant starting at #defines(780)
#include <wctype.h>
#endif
