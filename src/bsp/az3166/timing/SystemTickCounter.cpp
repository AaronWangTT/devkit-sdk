// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "SystemTickCounter.h"
#include "drivers/Ticker.h"
#include "hal/us_ticker_api.h"
#include "platform/mbed_critical.h"

static mbed::Ticker tickSampler;
static uint32_t previousTick;
static uint64_t elapsedMicroseconds;
static bool initialized = false;

static void sampleTickCounter(void)
{
    core_util_critical_section_enter();
    uint32_t currentTick = us_ticker_read();
    elapsedMicroseconds += static_cast<uint32_t>(currentTick - previousTick);
    previousTick = currentTick;
    core_util_critical_section_exit();
}

void SystemTickCounterInit(void)
{
    core_util_critical_section_enter();
    if (!initialized)
    {
        previousTick = us_ticker_read();
        elapsedMicroseconds = 0;
        initialized = true;
        tickSampler.attach_us(sampleTickCounter, 1000000);
    }
    core_util_critical_section_exit();
}

uint64_t SystemTickCounterRead(void)
{
    core_util_critical_section_enter();
    if (initialized)
    {
        sampleTickCounter();
    }
    uint64_t result = elapsedMicroseconds / 1000;
    core_util_critical_section_exit();
    return result;
}
