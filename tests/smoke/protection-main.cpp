#include "protection.hpp"
#include <cstdio>
#include <cstdlib>
#include <typeinfo>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 1;
    }
    const unsigned input = static_cast<unsigned>(std::strtoul(argv[1], nullptr, 10));
    SmokeBase *object = create_smoke_object();
    SmokeDerived *derived = dynamic_cast<SmokeDerived *>(object);
    if (!derived || typeid(*object) != typeid(SmokeDerived)) {
        return 2;
    }
    const unsigned result = object->evaluate(input);
    if (result != derived->evaluate(input)) {
        return 3;
    }
    delete object;

    const double fraction = evaluate_fraction(input);
    const double expected_fraction = (input & 1u) != 0
        ? (static_cast<double>(input % 97u) + 1.25) * 1.5
        : (static_cast<double>(input % 97u) - 2.5) * 0.75;
    if (fraction != expected_fraction) {
        return 4;
    }

    bool caught = false;
    try {
        throw_if_odd(input);
    } catch (const SmokeError &error) {
        caught = true;
        if (error.value != (input ^ 0x5a5a1234u)) {
            return 5;
        }
    } catch (...) {
        return 6;
    }
    if (caught != ((input & 1u) != 0)) {
        return 7;
    }

    const char *message = protected_message();
    unsigned hash = 0;
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(message); *p; ++p) {
        hash = hash * 131u + *p;
    }
    if (hash != 0x286ac30eu) {
        return 8;
    }
    std::printf("Arkari full protection smoke: OK %u %u %.3f %s\n", input, result, fraction, message);
    return 0;
}
