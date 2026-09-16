#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static std::map<int, std::string> stored;

#ifndef AZ3166_TEST_BASE
#define MBED_H
#define _UART_CLASS_
#include "EEPROMInterface.h"
#include "AzureConfiguration.h"

class UARTClass {
public:
    void printf(const char *, ...) {}
};
UARTClass Serial;

static bool saveFailure;
EEPROMInterface::EEPROMInterface() {}
EEPROMInterface::~EEPROMInterface() {}
int EEPROMInterface::write(uint8_t *value, int size, uint8_t zone)
{
    if (saveFailure) { return -1; }
    stored[zone] = std::string(reinterpret_cast<char *>(value), size);
    return 0;
}
int EEPROMInterface::read(uint8_t *value, int size, uint16_t, uint8_t zone)
{
    if (saveFailure) { return -1; }
    auto found = stored.find(zone);
    if (found == stored.end()) { return 0; }
    if (static_cast<size_t>(size) > found->second.size()) { size = found->second.size(); }
    memcpy(value, found->second.data(), size);
    return size;
}
int EEPROMInterface::saveDeviceConnectionString(char *value)
{
    return write(reinterpret_cast<uint8_t *>(value), strlen(value) + 1, AZ_IOT_HUB_ZONE_IDX);
}
int EEPROMInterface::saveX509Cert(char *value)
{
    return write(reinterpret_cast<uint8_t *>(value), strlen(value) + 1, STSAFE_ZONE_0_IDX);
}
#endif

#ifdef AZ3166_TEST_BASE
#include "../../../src/extensions/configuration/ConfigurationProvider.cpp"
#else
#include "../../../libraries/AzureIoT/platform/AzureConfiguration.cpp"

#define __AZURE_IOTHUB_H__
#define LogError(...)
extern "C" const char *getIoTHubConnectionString(void);
#include "../../../libraries/AzureIoT/src/AzureIotHub.cpp"

#define __MICO_H_
#define custom_log(...)
static const int kNoErr = 0;
static const int kParamErr = -1;
static const int kNotFoundErr = -2;
static const int kNoSpaceErr = -3;
static const int kInProgressErr = -4;
static const int kGeneralErr = -5;
#include "../../../src/extensions/http-server/helper.c"
#include "../../../src/extensions/http-server/http_parse.c"
#define MIN(first, second) ((first) < (second) ? (first) : (second))
#include "../../../src/extensions/http-server/httpd_wsgi.c"
#undef MIN

static std::string incomingBody;
static size_t incomingOffset;
static size_t receiveChunk = 31;
static bool receiveFailure;
static std::vector<std::string> incomingHeaders;
static size_t headerIndex;
static std::string multipartBoundary = "----test-boundary";

int httpd_recv(int, void *buffer, size_t length, int)
{
    if (receiveFailure) { return -1; }
    size_t available = incomingBody.size() - incomingOffset;
    size_t count = available < length ? available : length;
    if (count > receiveChunk) { count = receiveChunk; }
    memcpy(buffer, incomingBody.data() + incomingOffset, count);
    incomingOffset += count;
    return count;
}

int htsys_getln_soc(int, char *buffer, int capacity)
{
    if (headerIndex == incomingHeaders.size()) { return -kInProgressErr; }
    const std::string &header = incomingHeaders[headerIndex++];
    assert(header.size() < static_cast<size_t>(capacity));
    memcpy(buffer, header.c_str(), header.size() + 1);
    return header.size();
}

static int readField(void *context, const char *name, char *value, size_t capacity)
{
    const std::map<std::string, std::string> &fields = *static_cast<std::map<std::string, std::string> *>(context);
    auto found = fields.find(name);
    if (found == fields.end() || found->second.size() >= capacity) { return -1; }
    memcpy(value, found->second.c_str(), found->second.size() + 1);
    return 0;
}

static int readMultipartField(void *context, const char *name, char *value, size_t capacity)
{
    return httpd_get_tag_from_multipart_form(static_cast<char *>(context), &multipartBoundary[0], name, value, capacity);
}

static int readUrlEncodedField(void *context, const char *name, char *value, size_t capacity)
{
    return httpd_get_tag_from_post_data(static_cast<char *>(context), name, value, capacity - 1);
}
#endif

int main(void)
{
    size_t count = 99;
    const ConfigurationCommand *commands = GetConfigurationCommands(&count);
    char page[2048];
    void *settings = NULL;
#ifdef AZ3166_TEST_BASE
    assert(commands == NULL && count == 0);
    assert(GetConfigurationBodySize(7) == 0);
    assert(WriteConfigurationForm(7, page, sizeof(page)) == 0 && page[0] == '\0');
    assert(ReadConfigurationSettings(7, NULL, &settings) == 0 && settings == NULL);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) == 0 && page[0] == '\0');
    FreeConfigurationSettings(settings);
    assert(stored.empty());
    std::puts("PASS base configuration has no optional commands, fields, or writes");
#else
    assert(count == 3);
    for (size_t index = 0; index < count; ++index) { assert(commands[index].isPrivacy); }
    assert(WriteConfigurationForm(0, page, sizeof(page)) == 0);
    assert(WriteConfigurationForm(7, page, sizeof(page)) > 0);
    assert(strstr(page, "SymmetricKey") != NULL && strstr(page, "DeviceConnectionString") == NULL);
    assert(WriteConfigurationForm(7, page, 8) == -1);
    static_assert(AZ_IOT_HUB_ZONE_IDX == 5 && DPS_UDS_ZONE_IDX == 6, "Credential zones must not move");
    static_assert(AZ_IOT_HUB_MAX_LEN == 512 && DPS_UDS_MAX_LEN == 64, "Stored credential sizes must not change");

    std::map<std::string, std::string> fields = {{"DeviceConnectionString", "HostName=example;DeviceId=test;SharedAccessKey=fake"}, {"certificate", "test-certificate"}};
    ConfigurationForm form = {&fields, readField};
    assert(ReadConfigurationSettings(3, &form, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].c_str() == fields["DeviceConnectionString"]);
    assert(stored[STSAFE_ZONE_0_IDX].c_str() == fields["certificate"]);
    saveFailure = true;
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0 && strstr(page, "save failed") != NULL);
    saveFailure = false;
    FreeConfigurationSettings(settings);

    fields = {{"DPSEndpoint", "global.azure-devices-provisioning.net"}, {"ScopeId", "scope"}, {"RegistrationId", "device"}, {"SymmetricKey", "fake"}};
    assert(ReadConfigurationSettings(4, &form, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].c_str() == std::string("DPSEndpoint=global.azure-devices-provisioning.net;ScopeId=scope;RegistrationId=device;SymmetricKey=fake"));
    FreeConfigurationSettings(settings);
    fields.erase("SymmetricKey");
    assert(ReadConfigurationSettings(4, &form, &settings) != 0);
    FreeConfigurationSettings(settings);
    for (const char *name : {"DPSEndpoint", "ScopeId", "RegistrationId", "SymmetricKey"}) { fields[name] = std::string(128, 'x'); }
    assert(ReadConfigurationSettings(4, &form, &settings) != 0);
    FreeConfigurationSettings(settings);

    std::string multipart = "------test-boundary\r\nContent-Disposition: form-data; name=\"DeviceConnectionString\"\r\n\r\n" +
        std::string(AZ_IOT_HUB_MAX_LEN - 1, 'x') + "\r\n------test-boundary--\r\n";
    ConfigurationForm multipartForm = {&multipart[0], readMultipartField};
    assert(ReadConfigurationSettings(1, &multipartForm, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].size() == AZ_IOT_HUB_MAX_LEN);
    FreeConfigurationSettings(settings);
    multipart.insert(multipart.find("\r\n------test-boundary--"), 1, 'x');
    multipartForm.context = &multipart[0];
    assert(ReadConfigurationSettings(1, &multipartForm, &settings) != 0);
    FreeConfigurationSettings(settings);

    std::string urlEncoded = "DeviceConnectionString=" + std::string(AZ_IOT_HUB_MAX_LEN - 1, 'x') +
        "&certificate=test-certificate&end=1";
    ConfigurationForm urlForm = {&urlEncoded[0], readUrlEncodedField};
    assert(ReadConfigurationSettings(3, &urlForm, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].size() == AZ_IOT_HUB_MAX_LEN);
    FreeConfigurationSettings(settings);
    stored.clear();
    urlEncoded.insert(urlEncoded.find("&certificate="), 1, 'x');
    urlForm.context = &urlEncoded[0];
    assert(ReadConfigurationSettings(3, &urlForm, &settings) != 0);
    FreeConfigurationSettings(settings);
    assert(stored.empty());
    urlEncoded = "DeviceConnectionString=%78" + std::string(AZ_IOT_HUB_MAX_LEN - 1, 'x') +
        "&certificate=test-certificate&end=1";
    urlForm.context = &urlEncoded[0];
    assert(ReadConfigurationSettings(3, &urlForm, &settings) != 0);
    FreeConfigurationSettings(settings);
    assert(stored.empty());

    multipartBoundary.assign(70, 'b');
    incomingBody.clear();
    auto addPart = [](const char *name, const std::string &value) {
        incomingBody += "--" + multipartBoundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value + "\r\n";
    };
    addPart("input_ssid_method", "select");
    addPart("SSID", std::string(WIFI_SSID_MAX_LEN, 's'));
    addPart("PASS", std::string(WIFI_PWD_MAX_LEN, 'p'));
    addPart("DeviceConnectionString", std::string(AZ_IOT_HUB_MAX_LEN - 1, 'x'));
    addPart("certificate", std::string(AZ_IOT_X509_MAX_LEN, 'c'));
    incomingBody += "--" + multipartBoundary + "--\r\n";
    incomingHeaders = {"Content-Length: " + std::to_string(incomingBody.size()) + "\r\n",
        "Content-Type: multipart/form-data; boundary=" + multipartBoundary + "\r\n", "\r\n"};
    headerIndex = 0;
    incomingOffset = 0;
    httpd_request_t request = {};
    std::vector<char> requestBuffer(GetConfigurationRequestCapacity(3, WIFI_SSID_MAX_LEN + WIFI_PWD_MAX_LEN), '\0');
    assert(incomingBody.size() < requestBuffer.size());
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) == 0);
    assert(request.hdr_parsed == 1 && request.body_nbytes == static_cast<int>(incomingBody.size()));
    assert(std::string(requestBuffer.data()) == incomingBody);
    multipartForm.context = requestBuffer.data();
    assert(ReadConfigurationSettings(3, &multipartForm, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].size() == AZ_IOT_HUB_MAX_LEN);
    assert(stored[STSAFE_ZONE_0_IDX].size() == AZ_IOT_X509_MAX_LEN + 1);
    FreeConfigurationSettings(settings);
    stored.clear();

    incomingOffset = 0;
    request.remaining_bytes = request.body_nbytes;
    assert(httpd_get_data(&request, requestBuffer.data(), incomingBody.size() - 1) == 1);
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) == 0);
    incomingOffset = 0;
    request.remaining_bytes = request.body_nbytes;
    incomingBody.pop_back();
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) < 0);
    assert(requestBuffer[0] == '\0' && stored.empty());
    receiveFailure = true;
    incomingOffset = 0;
    request.remaining_bytes = request.body_nbytes;
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) < 0);
    receiveFailure = false;
    request.chunked = 1;
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) < 0);
    request.chunked = 0;
    request.hdr_parsed = 0;
    incomingHeaders.clear();
    headerIndex = 0;
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) < 0);
    assert(stored.empty());

    incomingBody.clear();
    auto addEncodedField = [](const char *name, size_t length, const char *encodedByte) {
        incomingBody += std::string(name) + "=";
        for (size_t index = 0; index < length; ++index) { incomingBody += encodedByte; }
        incomingBody += "&";
    };
    addEncodedField("SSID", WIFI_SSID_MAX_LEN, "%73");
    addEncodedField("PASS", WIFI_PWD_MAX_LEN, "%70");
    addEncodedField("DeviceConnectionString", AZ_IOT_HUB_MAX_LEN - 1, "%78");
    addEncodedField("certificate", AZ_IOT_X509_MAX_LEN, "%63");
    incomingBody += "end=1";
    assert(incomingBody.size() < requestBuffer.size());
    incomingOffset = 0;
    request.hdr_parsed = 1;
    request.body_nbytes = incomingBody.size();
    request.remaining_bytes = request.body_nbytes;
    assert(httpd_get_data(&request, requestBuffer.data(), requestBuffer.size() - 1) == 0);
    urlForm.context = requestBuffer.data();
    assert(ReadConfigurationSettings(3, &urlForm, &settings) == 0);
    assert(SaveConfigurationSettings(settings, page, sizeof(page)) > 0);
    assert(stored[AZ_IOT_HUB_ZONE_IDX].size() == AZ_IOT_HUB_MAX_LEN);
    assert(stored[STSAFE_ZONE_0_IDX].size() == AZ_IOT_X509_MAX_LEN + 1);
    FreeConfigurationSettings(settings);

    stored.clear();
    assert(getIoTHubConnectionString() == NULL);
    stored[AZ_IOT_HUB_ZONE_IDX] = std::string("saved-connection\0", 17);
    saveFailure = true;
    assert(getIoTHubConnectionString() == NULL);
    saveFailure = false;
    assert(std::string(getIoTHubConnectionString()) == "saved-connection");
    stored[AZ_IOT_HUB_ZONE_IDX] = "changed";
    assert(std::string(getIoTHubConnectionString()) == "saved-connection");
    free(connString);
    connString = NULL;
    stored.clear();
    char secret[DPS_UDS_MAX_LEN + 1];
    memset(secret, 'a', sizeof(secret) - 1);
    secret[sizeof(secret) - 1] = '\0';
    char command[] = "set_dps_uds";
    char *arguments[] = {command, secret};
    commands[1].function(2, arguments);
    assert(stored[DPS_UDS_ZONE_IDX].size() == sizeof(secret));
    stored.clear();
    secret[0] = '\0';
    commands[1].function(2, arguments);
    assert(stored.empty());
    std::puts("PASS Azure configuration fields, bounded parsing, failures, storage zones, and private commands");
#endif
    return 0;
}