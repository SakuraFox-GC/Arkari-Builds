#include "protection.hpp"
#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace {
volatile unsigned discount_thresholds[] = {10, 50};
volatile double handling_fee = 0.25;
}

SmokeBase::~SmokeBase() = default;
SmokeDerived::~SmokeDerived() = default;

double SmokeDerived::total(const InventoryRecord &record) const {
    double discount = 1.0;
    if (record.quantity >= discount_thresholds[1]) {
        discount = 0.8;
    } else if (record.quantity >= discount_thresholds[0]) {
        discount = 0.9;
    }
    return record.quantity * record.unit_price * discount + handling_fee;
}

SmokeBase *create_smoke_object() {
    return new SmokeDerived;
}

InventoryRecord parse_record(const std::string &text, unsigned line) {
    const auto first = text.find(',');
    const auto second = text.find(',', first == std::string::npos ? 0 : first + 1);
    if (first == std::string::npos || first == 0 || second == std::string::npos ||
        text.find(',', second + 1) != std::string::npos) {
        throw SmokeError(line, "Expected name,quantity,price");
    }
    const std::string quantity_text = text.substr(first + 1, second - first - 1);
    const std::string price_text = text.substr(second + 1);
    char *end = nullptr;
    errno = 0;
    const unsigned long quantity = std::strtoul(quantity_text.c_str(), &end, 10);
    if (errno || quantity_text.empty() || *end || quantity == 0 || quantity > 1000) {
        throw SmokeError(line, "Invalid quantity");
    }
    errno = 0;
    const double price = std::strtod(price_text.c_str(), &end);
    if (errno || price_text.empty() || *end || !std::isfinite(price) || price < 0 || price > 10000) {
        throw SmokeError(line, "Invalid price");
    }
    return {text.substr(0, first), static_cast<unsigned>(quantity), price};
}

const char *protected_message() {
    return "ARKARI_PROTECTED_LITERAL_7D2BC640";
}
