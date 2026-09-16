#include <DevkitDPSClient.h>
#include <DevKitMQTTClient.h>
#include <SystemFunc.h>
#include <SystemWeb.h>
#include <azure-iot/AzureConfiguration.h>

volatile bool exerciseCloudPaths = false;

void __sys_setup(void)
{
    EnableSystemWeb(WEB_SETTING_IOT_DPS_SYMMETRIC_KEY);
}

void setup()
{
    if (exerciseCloudPaths)
    {
        DevkitDPSSetAuthType(DPS_AUTH_SYMMETRIC_KEY);
        DevkitDPSClientStart("global.azure-devices-provisioning.net", "scope", "device");
        DevKitMQTTClient_Init(true, false);
        DevKitMQTTClient_SendEvent("{\"probe\":true}");
        DevKitMQTTClient_Close();
        (void)getIoTHubConnectionString();
    }
}

void loop()
{
}