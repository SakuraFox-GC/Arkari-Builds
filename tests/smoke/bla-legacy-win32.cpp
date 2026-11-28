// Compile directly to COFF: serializing IR first masks malformed i32 keys.
extern "C" int consume(unsigned value, const char *label);
volatile unsigned legacy_global_value = 17;

extern "C" int legacy_win32_regression(unsigned input) {
    try {
        return consume(input ^ legacy_global_value, "normal");
    } catch (unsigned value) {
        return consume(value + legacy_global_value, "caught");
    } catch (...) {
        return -1;
    }
}
