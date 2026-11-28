__declspec(noinline) unsigned arithmetic(unsigned x, unsigned y) {
    unsigned value = (x + y) ^ (x - y);
    for (unsigned i = 0; i < 16; ++i) {
        value = ((value | y) + (x & value)) ^ (value - x);
        value += (x + i) ^ (y - i);
    }
    return value;
}

__declspec(noinline) __attribute__((annotate("-bla-mba -bla-opaque")))
unsigned annotation_disabled(unsigned x, unsigned y) {
    return arithmetic(x, y) + x - y;
}

__declspec(noinline) __attribute__((annotate("+bla-mba +bla-opaque ^bla-mba=3 ^bla-opaque=2")))
unsigned annotation_enabled(unsigned x, unsigned y) {
    return (x + y) ^ (x - y);
}

void entry(void) {
    volatile unsigned result = arithmetic(17, 23);
    (void)result;
}
