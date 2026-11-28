#include <cstdio>

extern "C" __declspec(dllimport) unsigned bla_export(unsigned value);

int main() {
    const unsigned inputs[] = {0u, 1u, 17u, 100u, 0x7fffffffu, 0xffffffffu};
    unsigned digest = 0;
    for (unsigned value : inputs) {
        const unsigned expected = (value & 1u) != 0
            ? (value ^ 0x11223344u) + 0x55667788u
            : value * 33u + 17u;
        const unsigned actual = bla_export(value);
        if (actual != expected) {
            return 1;
        }
        digest = digest * 33u + actual;
    }
    std::printf("BLA DLL: %08x\n", digest);
    return 0;
}
