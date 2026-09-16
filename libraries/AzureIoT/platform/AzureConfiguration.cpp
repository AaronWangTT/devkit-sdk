#include "ConfigurationProvider.h"
#include "AzureConfiguration.h"
#include "EEPROMInterface.h"
#include "UARTClass.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern UARTClass Serial;

struct AzureWebSettings
{
    char *connectionString;
    char *certificate;
};

static int appendText(char *destination, size_t capacity, const char *text)
{
    size_t used = strlen(destination);
    size_t length = strlen(text);
    if (used >= capacity || length >= capacity - used) { return -1; }
    memcpy(destination + used, text, length + 1);
    return 0;
}

static void storeCredential(int argc, char **argv, int zone, size_t maximum, bool exact)
{
    if (argc != 2 || argv[1] == NULL)
    {
        Serial.printf("Usage: %s <value>.\r\n", argv[0]);
        return;
    }
    size_t length = strlen(argv[1]);
    if (length == 0 || (exact ? length != maximum : length + 1 > maximum))
    {
        Serial.printf("Invalid credential length.\r\n");
        return;
    }
    EEPROMInterface eeprom;
    uint8_t verification[AZ_IOT_HUB_MAX_LEN + 1];
    if (eeprom.write(reinterpret_cast<uint8_t *>(argv[1]), length + 1, zone) != 0 ||
        eeprom.read(verification, length + 1, 0, zone) != static_cast<int>(length + 1) ||
        memcmp(verification, argv[1], length + 1) != 0)
    {
        Serial.printf("ERROR: Failed to write or verify EEPROM: 0x%02x.\r\n", zone);
        return;
    }
    Serial.printf("INFO: Credential saved.\r\n");
}

static void setIoTHub(int argc, char **argv)
{
    storeCredential(argc, argv, AZ_IOT_HUB_ZONE_IDX, AZ_IOT_HUB_MAX_LEN, false);
}

static void setDpsSecret(int argc, char **argv)
{
    storeCredential(argc, argv, DPS_UDS_ZONE_IDX, DPS_UDS_MAX_LEN, true);
}

static void setDpsConnection(int argc, char **argv)
{
    storeCredential(argc, argv, AZ_IOT_HUB_ZONE_IDX, AZ_IOT_HUB_MAX_LEN, false);
}

const ConfigurationCommand *GetConfigurationCommands(size_t *count)
{
    static const ConfigurationCommand commands[] = {
        {"set_az_iothub", "Set IoT Hub device connection string", true, setIoTHub},
        {"set_dps_uds", "Set DPS Unique Device Secret (UDS) for X.509 certificates", true, setDpsSecret},
        {"set_az_iotdps", "Set DPS connection string", true, setDpsConnection}
    };
    *count = sizeof(commands) / sizeof(commands[0]);
    return commands;
}

int WriteConfigurationForm(int options, char *destination, size_t capacity)
{
    if (destination == NULL || capacity == 0) { return -1; }
    destination[0] = '\0';
    if (GetConfigurationBodySize(options) == 0) { return 0; }
    if (appendText(destination, capacity, "<div><fieldset><legend>Azure IoT Settings</legend>") != 0) { return -1; }
    if (options & WEB_SETTING_IOT_DPS_SYMMETRIC_KEY)
    {
        if (appendText(destination, capacity, "<div class=\"input-group fluid\"><input type=\"text\" name=\"DPSEndpoint\" id=\"DPSEndpoint\" placeholder=\"The DPS endpoint\" value=\"global.azure-devices-provisioning.net\"></div><div class=\"input-group fluid\"><input type=\"text\" name=\"ScopeId\" id=\"ScopeId\" placeholder=\"The DPS ID Scope\"></div><div class=\"input-group fluid\"><input type=\"text\" name=\"RegistrationId\" id=\"RegistrationId\" placeholder=\"The Registration ID\"></div><div class=\"input-group fluid\"><input type=\"password\" name=\"SymmetricKey\" id=\"SymmetricKey\" placeholder=\"The symmetric key\"></div>") != 0) { return -1; }
    }
    else
    {
        if ((options & WEB_SETTING_IOT_DEVICE_CONN_STRING) &&
            appendText(destination, capacity, "<div class=\"input-group fluid\"><input type=\"password\" name=\"DeviceConnectionString\" id=\"DeviceConnectionString\" placeholder=\"IoT Device Connection String\"></div>") != 0) { return -1; }
        if ((options & WEB_SETTING_IOT_CERT) &&
            appendText(destination, capacity, "<div class=\"input-group fluid\"><textarea name=\"certificate\" rows=\"5\" placeholder=\"X.509 Certificate\"></textarea></div>") != 0) { return -1; }
    }
    if (appendText(destination, capacity, "</fieldset></div>") != 0) { return -1; }
    return static_cast<int>(strlen(destination));
}

size_t GetConfigurationBodySize(int options)
{
    if (options & WEB_SETTING_IOT_DPS_SYMMETRIC_KEY) { return AZ_IOT_HUB_MAX_LEN; }
    return ((options & WEB_SETTING_IOT_DEVICE_CONN_STRING) ? AZ_IOT_HUB_MAX_LEN : 0) +
        ((options & WEB_SETTING_IOT_CERT) ? AZ_IOT_X509_MAX_LEN : 0);
}

static int readRequiredField(const ConfigurationForm *form, const char *name, char *value, size_t capacity)
{
    int result = form->read(form->context, name, value, capacity);
    value[capacity - 1] = '\0';
    return result != 0 ? result : (value[0] == '\0' ? -1 : 0);
}

void FreeConfigurationSettings(void *settings)
{
    AzureWebSettings *values = static_cast<AzureWebSettings *>(settings);
    if (values != NULL)
    {
        free(values->connectionString);
        free(values->certificate);
        free(values);
    }
}

int ReadConfigurationSettings(int options, const ConfigurationForm *form, void **settings)
{
    *settings = NULL;
    if (GetConfigurationBodySize(options) == 0) { return 0; }
    if (form == NULL || form->read == NULL) { return -1; }
    AzureWebSettings *values = static_cast<AzureWebSettings *>(calloc(1, sizeof(AzureWebSettings)));
    if (values == NULL) { return -1; }
    *settings = values;
    if (options & (WEB_SETTING_IOT_DEVICE_CONN_STRING | WEB_SETTING_IOT_DPS_SYMMETRIC_KEY))
    {
        values->connectionString = static_cast<char *>(calloc(AZ_IOT_HUB_MAX_LEN + 1, 1));
        if (values->connectionString == NULL) { return -1; }
    }
    if (options & WEB_SETTING_IOT_DPS_SYMMETRIC_KEY)
    {
        static const char *names[] = {"DPSEndpoint", "ScopeId", "RegistrationId", "SymmetricKey"};
        char value[AZ_IOT_HUB_MAX_LEN / 4 + 1];
        for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); ++index)
        {
            memset(value, 0, sizeof(value));
            if (readRequiredField(form, names[index], value, sizeof(value)) != 0 ||
                (index != 0 && appendText(values->connectionString, AZ_IOT_HUB_MAX_LEN, ";") != 0) ||
                appendText(values->connectionString, AZ_IOT_HUB_MAX_LEN, names[index]) != 0 ||
                appendText(values->connectionString, AZ_IOT_HUB_MAX_LEN, "=") != 0 ||
                appendText(values->connectionString, AZ_IOT_HUB_MAX_LEN, value) != 0) { return -1; }
        }
    }
    else
    {
        if (values->connectionString != NULL &&
            readRequiredField(form, "DeviceConnectionString", values->connectionString, AZ_IOT_HUB_MAX_LEN) != 0) { return -1; }
        if (options & WEB_SETTING_IOT_CERT)
        {
            values->certificate = static_cast<char *>(calloc(AZ_IOT_X509_MAX_LEN + 1, 1));
            if (values->certificate == NULL ||
                readRequiredField(form, "certificate", values->certificate, AZ_IOT_X509_MAX_LEN + 1) != 0) { return -1; }
        }
    }
    return 0;
}

int SaveConfigurationSettings(void *settings, char *destination, size_t capacity)
{
    if (destination == NULL || capacity == 0) { return -1; }
    destination[0] = '\0';
    AzureWebSettings *values = static_cast<AzureWebSettings *>(settings);
    if (values == NULL) { return 0; }
    EEPROMInterface eeprom;
    if (values->connectionString != NULL)
    {
        const char *status = eeprom.saveDeviceConnectionString(values->connectionString) == 0 ? "saved" : "save failed";
        if (appendText(destination, capacity, "<tr><td>IoT Device Connection String - ") != 0 ||
            appendText(destination, capacity, status) != 0 ||
            appendText(destination, capacity, "</td></tr>") != 0) { return -1; }
    }
    if (values->certificate != NULL)
    {
        const char *status = eeprom.saveX509Cert(values->certificate) == 0 ? "saved" : "save failed";
        if (appendText(destination, capacity, "<tr><td>X.509 Certificate - ") != 0 ||
            appendText(destination, capacity, status) != 0 ||
            appendText(destination, capacity, "</td></tr>") != 0) { return -1; }
    }
    return static_cast<int>(strlen(destination));
}