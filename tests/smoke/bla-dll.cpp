extern "C" __declspec(dllexport) unsigned bla_export(unsigned value) {
    try {
        if ((value & 1u) != 0) {
            throw value ^ 0x11223344u;
        }
        return value * 33u + 17u;
    } catch (unsigned encoded) {
        return encoded + 0x55667788u;
    }
}
