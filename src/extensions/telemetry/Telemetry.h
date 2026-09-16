// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. 

#ifndef __SYSTEM_TELEMERTY_H__
#define __SYSTEM_TELEMERTY_H__

#ifdef __cplusplus
extern "C"{
#endif  // __cplusplus

    // Initialize the system telemetry
    void telemetry_init();
    
    void send_telemetry_data(const char *context, const char *event, const char *message);
        
    void send_telemetry_data_async(const char *context, const char *event, const char *message);
    
    void send_telemetry_data_sync(const char *context, const char *event, const char *message);

#ifdef __cplusplus
}
#endif

#endif // __SYSTEM_TELEMERTY_H__