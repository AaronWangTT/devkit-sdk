#include <OTAFirmwareUpdate.h>

static_assert(sizeof(OTADownloadFirmware(nullptr, nullptr)) == sizeof(int),
    "The C++ OTA API must accept an omitted certificate.");
static_assert(sizeof(OTADownloadFirmware(nullptr, nullptr, nullptr)) == sizeof(int),
    "The C++ OTA API must accept an explicit certificate.");

int OTAHeaderCppLinkTest()
{
    int (*volatile downloadFirmware)(const char *, uint16_t *, const char *) = OTADownloadFirmware;
    int (*volatile applyFirmware)(int, uint16_t) = OTAApplyNewFirmware;
    return downloadFirmware != NULL && applyFirmware != NULL;
}