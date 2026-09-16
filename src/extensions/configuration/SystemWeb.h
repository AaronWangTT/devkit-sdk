// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. 

#ifndef __SYSTEM_WEB_H__
#define __SYSTEM_WEB_H__

#include "mbed.h"

#ifdef __cplusplus
extern "C"{
#endif  // __cplusplus

void EnableSystemWeb(int extFunctions);

void StartupSystemWeb(void);

#ifdef __cplusplus
}
#endif  // __cplusplus

#endif  // __SYSTEM_WEB_H__
