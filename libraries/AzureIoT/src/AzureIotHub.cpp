// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "AzureIotHub.h"
#include "EEPROMInterface.h"
#include "azure-iot/AzureConfiguration.h"
#include <string.h>

static char *connString = NULL;

const char *getIoTHubConnectionString(void)
{
    if (connString == NULL)
    {
        uint8_t storedString[AZ_IOT_HUB_MAX_LEN + 1] = {'\0'};
        EEPROMInterface eeprom;
        int result = eeprom.read(storedString, AZ_IOT_HUB_MAX_LEN, 0, AZ_IOT_HUB_ZONE_IDX);
        if (result < 0)
        {
            LogError("Unable to get the azure iot connection string from EEPROM. Please set the value in configuration mode.");
            return NULL;
        }
        if (result == 0)
        {
            LogError("The connection string is empty.\r\nPlease set the value in configuration mode.");
            return NULL;
        }
        connString = strdup((char*)storedString);
    }
    return connString;
}