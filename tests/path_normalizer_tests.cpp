#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

#include "../src/path_normalizer.h"

namespace {

int failures = 0;

void Expect(std::wstring input, bool expected_changed,
            std::wstring_view expected_result) {
  const bool changed = tc_unc_guard::NormalizePath(input);
  if (changed != expected_changed || input != expected_result) {
    std::wcerr << L"Unexpected result: changed=" << changed << L", value="
               << input << L'\n';
    ++failures;
  }
}

}  // namespace

int main() {
  Expect(LR"(с:\Windows)", true, LR"(c:\Windows)");
  Expect(LR"(С:\Windows)", true, LR"(C:\Windows)");
  Expect(LR"(с:)", true, LR"(c:)");
  Expect(LR"(C:\Windows)", false, LR"(C:\Windows)");
  Expect(LR"(folder\с:\Windows)", false, LR"(folder\с:\Windows)");
  Expect(LR"(\\ph2-433-24324\с$)", true, LR"(\\ph2-433-24324\c$)");
  Expect(LR"(\\ph2-433-24324\С$\Windows)", true,
         LR"(\\ph2-433-24324\C$\Windows)");
  Expect(LR"(\\?\UNC\server\с$\Temp)", true,
         LR"(\\?\UNC\server\c$\Temp)");
  Expect(LR"(\\server\c$)", false, LR"(\\server\c$)");
  Expect(LR"(\\server\сache$)", false, LR"(\\server\сache$)");
  Expect(LR"(\\server\с)", false, LR"(\\server\с)");
  Expect(LR"(C:\с$)", false, LR"(C:\с$)");
  Expect(LR"(\\\server\с$)", false, LR"(\\\server\с$)");
  Expect(LR"(\\с$)", false, LR"(\\с$)");

  if (failures != 0) {
    std::cerr << failures << " test(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "All path normalization tests passed\n";
  return EXIT_SUCCESS;
}
