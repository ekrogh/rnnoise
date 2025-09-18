// Simple runtime smoke test: prints selected architecture
#include <stdio.h>
#include "cpu_support.h"

const char *arch_name(int a) {
    switch (a) {
        case 0: return "c (no sse4.1)";
        case 1: return "sse4.1";
        case 2: return "avx2";
        default: return "unknown";
    }
}

int main(void) {
    int arch = rnn_select_arch();
    printf("rnnoise selected arch = %d (%s)\n", arch, arch_name(arch));
    return 0;
}
