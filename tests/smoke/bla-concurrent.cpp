#include <cstdio>
#include <thread>

__declspec(noinline) unsigned calculate(unsigned x) {
    unsigned result = x ^ 0x13579bdfu;
    for (unsigned i = 0; i < 16; ++i) {
        if ((result & 1u) != 0) {
            result = (result + x) ^ (i * 0x1020304u);
        } else {
            result = (result | x) + (result & 0x76543210u);
        }
    }
    return result;
}

int main() {
    unsigned results[4] = {};
    std::thread workers[4];
    for (unsigned worker = 0; worker < 4; ++worker) {
        workers[worker] = std::thread([&, worker] {
            unsigned value = 0;
            for (unsigned i = 0; i < 2000; ++i) {
                value = value * 33u + calculate(i + worker * 10000u);
            }
            results[worker] = value;
        });
    }
    for (auto &worker : workers) {
        worker.join();
    }
    std::printf("BLA concurrent: %08x %08x %08x %08x\n", results[0], results[1], results[2], results[3]);
    return 0;
}
