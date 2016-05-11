// Test linking with an LLVM bitcode file

// RUN: %ldc -c -output-bc -I%S %S/inputs/link_bitcode_input.d -of=%t.bc
// RUN: %ldc -c -output-bc -I%S %S/inputs/link_bitcode_input3.d -of=%t3.bc
// RUN: %ldc -c -output-bc -I%S %S/inputs/link_bitcode_import.d -of=%timport.bc
// RUN: %ldc -c -singleobj -output-bc %t.bc %t3.bc %s
// RUN: %ldc -c -singleobj -I%S %t.bc %s %S/inputs/link_bitcode_input3.d
// RUN: %ldc -c -singleobj -I%S %t.bc %S/inputs/link_bitcode_input3.d %s
// RUN: %ldc -c -I%S %t.bc %S/inputs/link_bitcode_input3.d %s

// Check combination with `-internalize`
// RUN: %ldc -I%S %t.bc %t3.bc %timport.bc -internalize -internalize-public-api-list=main -run %s

// Defined in input/link_bitcode_input.d
extern(C) int return_seven();

void main() {
  assert( return_seven() == 7 );
}
