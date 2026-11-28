unsigned shared(unsigned value);
volatile unsigned input = 17;

void entry(void) {
    volatile unsigned result = shared(input);
    (void)result;
}
