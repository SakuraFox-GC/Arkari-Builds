#pragma once
#include <stdexcept>
#include <string>

#ifndef __ARKARI__
#error Expected an Arkari compiler
#endif

struct InventoryRecord {
    std::string name;
    unsigned quantity;
    double unit_price;
};

struct SmokeBase {
    virtual ~SmokeBase();
    virtual double total(const InventoryRecord &record) const = 0;
};

struct SmokeDerived final : SmokeBase {
    ~SmokeDerived() override;
    double total(const InventoryRecord &record) const override;
};

struct SmokeError : std::runtime_error {
    unsigned line;
    SmokeError(unsigned line, const char *reason) : std::runtime_error(reason), line(line) {}
};

__attribute__((noinline)) SmokeBase *create_smoke_object();
__attribute__((noinline)) InventoryRecord parse_record(const std::string &text, unsigned line);
__attribute__((noinline)) const char *protected_message();
