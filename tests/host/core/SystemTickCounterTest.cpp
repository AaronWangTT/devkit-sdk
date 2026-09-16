#include <cassert>
#include <cstdint>
#include <cstdio>

#define MBED_TICKER_H
#define MBED_US_TICKER_API_H
#define __MBED_UTIL_CRITICAL_H__

static uint32_t hardwareTick = UINT32_MAX - 1500;
static unsigned criticalDepth;
static unsigned attachmentCount;
static uint32_t samplePeriod;
static void (*sampleCallback)(void);
static void (*pendingInterrupt)(void);

extern "C" void core_util_critical_section_enter(void)
{
    ++criticalDepth;
}

extern "C" void core_util_critical_section_exit(void)
{
    assert(criticalDepth > 0);
    --criticalDepth;
    if (criticalDepth == 0 && pendingInterrupt != NULL)
    {
        void (*callback)(void) = pendingInterrupt;
        pendingInterrupt = NULL;
        callback();
    }
}

extern "C" uint32_t us_ticker_read(void)
{
    assert(criticalDepth > 0);
    return hardwareTick;
}

namespace mbed {
class Ticker {
public:
    void attach_us(void (*callback)(void), uint32_t period)
    {
        assert(criticalDepth > 0);
        ++attachmentCount;
        sampleCallback = callback;
        samplePeriod = period;
    }
};
}

#include "../../../src/bsp/az3166/timing/SystemTickCounter.cpp"

int main(void)
{
    assert(SystemTickCounterRead() == 0);
    SystemTickCounterInit();
    assert(attachmentCount == 1);
    assert(samplePeriod == 1000000);
    assert(SystemTickCounterRead() == 0);

    hardwareTick += 999;
    assert(SystemTickCounterRead() == 0);
    hardwareTick += 1001;
    assert(SystemTickCounterRead() == 2);
    SystemTickCounterInit();
    assert(attachmentCount == 1);
    assert(SystemTickCounterRead() == 2);

    uint64_t elapsed = 2000;
    const uint64_t sampleCount = (UINT64_C(1) << 32) / 1000 + 10;
    for (uint64_t sample = 0; sample < sampleCount; ++sample)
    {
        hardwareTick += samplePeriod;
        elapsed += samplePeriod;
        sampleCallback();
    }
    assert(SystemTickCounterRead() == elapsed / 1000);
    assert(SystemTickCounterRead() > UINT32_MAX);

    hardwareTick += 7654;
    elapsed += 7654;
    pendingInterrupt = sampleCallback;
    assert(SystemTickCounterRead() == elapsed / 1000);
    assert(SystemTickCounterRead() == elapsed / 1000);
    assert(pendingInterrupt == NULL);
    assert(criticalDepth == 0);
    std::puts("PASS system tick initialization, sub-ms precision, rollover, 49-day uptime, and serialized interrupt reads");
    return 0;
}