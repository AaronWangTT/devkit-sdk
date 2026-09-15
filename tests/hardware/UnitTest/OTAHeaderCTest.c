#include <OTAFirmwareUpdate.h>

int OTAHeaderCLinkTest(void)
{
    int (*volatile downloadFirmware)(const char *, uint16_t *, const char *) = OTADownloadFirmware;
    int (*volatile applyFirmware)(int, uint16_t) = OTAApplyNewFirmware;
    return downloadFirmware != NULL && applyFirmware != NULL;
}