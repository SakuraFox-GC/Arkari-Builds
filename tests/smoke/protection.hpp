#pragma once

#ifndef __ARKARI__
#error Expected an Arkari compiler
#endif

struct SmokeBase {
    virtual ~SmokeBase();
    virtual unsigned evaluate(unsigned input) const = 0;
};

struct SmokeDerived final : SmokeBase {
    ~SmokeDerived() override;
    unsigned evaluate(unsigned input) const override;
};

struct SmokeError {
    unsigned value;
};

__attribute__((noinline)) SmokeBase *create_smoke_object();
__attribute__((noinline)) double evaluate_fraction(unsigned input);
__attribute__((noinline)) const char *protected_message();
__attribute__((noinline)) void throw_if_odd(unsigned input);
