#include <cstdio>

__declspec(noinline) unsigned calculate(unsigned x, unsigned y) {
    unsigned value = (x + y) ^ (x - y);
    value += (x | y) - (x & y);
    for (unsigned i = 0; i < 8; ++i) {
        value = ((value + x) ^ y) + ((value | y) & (x - i));
        value ^= (x + i) & (y - i);
    }
    return value;
}

int main() {
    const unsigned boundaries[] = {0u, 1u, 2u, 0x7fffffffu, 0x80000000u, 0xfffffffeu, 0xffffffffu};
    unsigned digest = 0x31415926u;
    for (unsigned x : boundaries) {
        for (unsigned y : boundaries) {
            digest = (digest << 7) | (digest >> 25);
            digest ^= calculate(x, y);
        }
    }
    unsigned state = 0x12345678u;
    for (unsigned i = 0; i < 4096; ++i) {
        state = state * 1664525u + 1013904223u;
        const unsigned x = state;
        state = state * 1664525u + 1013904223u;
        digest = digest * 33u + calculate(x, state);
    }
    std::printf("BLA arithmetic: %08x\n", digest);
    return 0;
}
