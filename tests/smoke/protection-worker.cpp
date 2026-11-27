#include "protection.hpp"

namespace {
volatile unsigned global_bias = 0x13579bdfu;
volatile unsigned global_words[] = {0x10203040u, 0x55667788u, 0xabcdef01u, 0x76543210u};
volatile double global_scale = 1.5;
}

SmokeBase::~SmokeBase() = default;
SmokeDerived::~SmokeDerived() = default;

unsigned SmokeDerived::evaluate(unsigned input) const {
    unsigned result = input ^ global_bias;
    for (unsigned i = 0; i < 8; ++i) {
        switch ((input + i) & 3u) {
        case 0: result += global_words[i & 3u]; break;
        case 1: result ^= 0xa5b6c7d8u; break;
        case 2: result = (result << 5) | (result >> 27); break;
        default: result = result * 33u + 17u; break;
        }
        if ((result & 1u) != 0) {
            result ^= global_bias;
        } else {
            result += input + 0x91827364u;
        }
    }
    return result;
}

SmokeBase *create_smoke_object() {
    return new SmokeDerived;
}

double evaluate_fraction(unsigned input) {
    const double value = static_cast<double>(input % 97u);
    if ((input & 1u) != 0) {
        return (value + 1.25) * global_scale;
    }
    return (value - 2.5) * 0.75;
}

const char *protected_message() {
    return "ARKARI_PROTECTED_LITERAL_7D2BC640";
}

void throw_if_odd(unsigned input) {
    if ((input & 1u) != 0) {
        throw SmokeError{input ^ 0x5a5a1234u};
    }
}
