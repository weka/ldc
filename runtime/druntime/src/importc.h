/* This .h file is to be #include'd by ImportC files first in order provide
 * adjustments to the source to account for various C compiler extensions
 * not supported by ImportC.
 *
 * Copyright: Copyright D Language Foundation 2022
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright
 * Source: $(DRUNTIMESRC importc.h)
 */

/**********************
 * For special casing ImportC code.
 */
#define __IMPORTC__ 1

/********************
 * Some compilers define `__restrict` instead of `restrict` as C++ compilers don't
 * recognize `restrict` as a keyword.
 * ImportC assigns no semantics to `restrict`, so just ignore the keyword.
 */
#define __restrict
#define __restrict__

/**********************
 * Some old pre-Ansi headers use these
 */
#define __signed__ signed
#define __asm__ asm
#define __asm asm
#define __inline__ inline
#define __inline inline

/********************
 * Clang nullability extension used by macOS headers.
 */
#define _Nonnull
#define _Nullable
#define _Null_unspecified

/********************
 * This is a Microsoft C function calling convention not supported by ImportC,
 * so ignore it.
 */
#define __fastcall

#define __forceinline
#undef _Check_return_
//#define _Check_return_
#define __pragma(x)

#undef _GLIBCXX_USE_FLOAT128

/* Microsoft builtin types */
#define __int8 char
#define __int16 short
#define __int32 int
#define __int64 long long

/*********************
 * Obsolete detritus
 */
#define __cdecl
#define __ss
#define __cs
#define __far
#define __near
#define __handle
#define __pascal

/****************************
 * __extension__ is a GNU C extension. It suppresses warnings
 * when placed before an expression.
 */
#define __extension__  /* ignore it, as ImportC doesn't do warnings */

/********************************
 * __has_extension is a clang thing:
 *    https://clang.llvm.org/docs/LanguageExtensions.html
 * ImportC no has extensions.
 */
#undef __has_feature
#define __has_feature(x) 0

#undef __has_extension
#define __has_extension(x) 0

/*************************************
 * OS-specific macros
 */
#if __APPLE__
#define __builtin___memmove_chk(dest, src, len, x) memmove(dest,src,len)  // put it back to memmove()
#define __builtin___memcpy_chk(dest, src, len, x) memcpy(dest,src,len)
#define __builtin___memset_chk(dest, val, len, x) memset(dest,val,len)
#define __builtin___stpcpy_chk(dest, src, x) stpcpy(dest,src)
#define __builtin___stpncpy_chk(dest, src, len, x) stpncpy(dest,src,len)
#define __builtin___strcat_chk(dest, src, x) strcat(dest,src)
#define __builtin___strcpy_chk(dest, src, x) strcpy(dest,src)
#define __builtin___strncat_chk(dest, src, len, x) strncat(dest,src,len)
#define __builtin___strncpy_chk(dest, src, len, x) strncpy(dest,src,len)
#endif

#if __FreeBSD__
#endif

#if _MSC_VER
//#undef _Post_writable_size
//#define _Post_writable_size(x) // consider #include <no_sal2.h>
#endif

/****************************
 * Define it to do what other C compilers do.
 */
#define __builtin_offsetof(t,i) ((typeof(sizeof(0)))((char *)&((t *)0)->i - (char *)0))

#define __builtin_bit_cast(t,e) (*(t*)(void*)&(e))

/***************************
 * C11 6.10.8.3 Conditional feature macros
 */
#define __STDC_NO_VLA__ 1

#if linux  // Microsoft won't allow the following macro
// Ubuntu's assert.h uses this
#define __PRETTY_FUNCTION__ __func__

#define _Float128 long double
#define __float128 long double
#endif

#if __APPLE__
#undef __SIZEOF_INT128__
#endif
