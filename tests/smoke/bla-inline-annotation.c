static __attribute__((annotate("+bla-mba -bla-opaque ^bla-mba=3")))
unsigned inline_enabled(unsigned x, unsigned y) {
    return (x + y) ^ (x - y);
}

static __attribute__((annotate("-bla-mba -bla-opaque")))
unsigned inline_disabled(unsigned x, unsigned y) {
    return (x | y) - (x & y);
}

unsigned annotation_caller(unsigned x, unsigned y) {
    return inline_enabled(x, y) + inline_disabled(x, y);
}
