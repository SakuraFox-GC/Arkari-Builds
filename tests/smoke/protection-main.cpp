#include "protection.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <typeinfo>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 1;
    }
    const unsigned minimum = static_cast<unsigned>(std::strtoul(argv[1], nullptr, 10));
    std::ifstream input("inventory.csv");
    if (!input) {
        return 2;
    }
    std::vector<InventoryRecord> records;
    std::string text;
    unsigned line = 0, rejected = 0;
    while (std::getline(input, text)) {
        ++line;
        try {
            records.push_back(parse_record(text, line));
        } catch (const SmokeError &error) {
            if (error.line != line || !*error.what()) {
                return 3;
            }
            ++rejected;
        } catch (...) {
            return 4;
        }
    }
    if (input.bad() || records.size() != 12 || rejected != 2) {
        return 5;
    }
    std::sort(records.begin(), records.end(), [](const auto &a, const auto &b) {
        return a.name < b.name;
    });

    std::unique_ptr<SmokeBase> model(create_smoke_object());
    SmokeBase *base = model.get();
    SmokeDerived *derived = dynamic_cast<SmokeDerived *>(base);
    if (!derived || typeid(*base) != typeid(SmokeDerived)) {
        return 6;
    }
    unsigned count = 0, units = 0, digest = 0x13579bdfu;
    double total = 0;
    for (const auto &record : records) {
        if (record.quantity < minimum) {
            continue;
        }
        const double amount = base->total(record);
        if (amount != derived->total(record)) {
            return 7;
        }
        ++count;
        units += record.quantity;
        total += amount;
        for (unsigned char ch : record.name) {
            digest = (digest ^ ch) * 16777619u;
        }
        digest ^= record.quantity;
    }

    const char *message = protected_message();
    unsigned hash = 0;
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(message); *p; ++p) {
        hash = hash * 131u + *p;
    }
    if (hash != 0x286ac30eu) {
        return 8;
    }
    std::printf("Arkari full protection smoke: OK min=%u records=%u units=%u rejected=%u total=%.2f hash=%08x %s\n",
        minimum, count, units, rejected, total, digest, message);
    return 0;
}
