//===-- driver/report_timing.h - LDC command line options ----------*- C++
//-*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// Reports timing during compilation
//
//===----------------------------------------------------------------------===//

#ifndef LDC_DRIVER_REPORTTIMING_H
#define LDC_DRIVER_REPORTTIMING_H

#include "ddmd/globals.h"

#include <chrono>

namespace {
template <typename... Args>
std::string string_format(const std::string &format, Args... args) {
  size_t size =
      snprintf(nullptr, 0, format.c_str(), args...) + 1; // Extra space for '\0'
  std::unique_ptr<char[]> buf(new char[size]);
  snprintf(buf.get(), size, format.c_str(), args...);
  return std::string(buf.get(),
                     buf.get() + size - 1); // We don't want the '\0' inside
}
}

namespace timing {

void printCurrentTime(const char *name);
// void endTime(const char *name);

struct PrintTimeSpentInScope {
  std::string str;
  std::chrono::high_resolution_clock::time_point t1;

  PrintTimeSpentInScope(std::string &&name) {
    using namespace std::chrono;
    if (true || global.params.verboseCompileTimings) {
      str = name;

      t1 = high_resolution_clock::now();
    }
  }
  template <typename... Args>
  PrintTimeSpentInScope(std::string name, Args... args) {
    using namespace std::chrono;
    if (true || global.params.verboseCompileTimings) {
      str = string_format(name, args...);

      t1 = high_resolution_clock::now();
    }
  }
  ~PrintTimeSpentInScope() {
    using namespace std::chrono;
    if (true || global.params.verboseCompileTimings) {
      auto t2 = high_resolution_clock::now();
      auto msecs = duration_cast<std::chrono::milliseconds>(t2 - t1).count();
      std::cout << str << ", " << msecs << " ms\n";
    }
  }
};

} // namespace timing

#endif
