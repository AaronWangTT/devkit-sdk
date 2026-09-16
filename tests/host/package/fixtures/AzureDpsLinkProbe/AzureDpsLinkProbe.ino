#include <DevkitDPSClient.h>
#include <DevKitMQTTClient.h>

volatile bool exerciseCloudPaths = false;

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