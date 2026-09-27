#include <OTAFirmwareUpdate.h>
#include <OTAStaging.h>

int OTAHeaderCLinkTest(void)
{
    int (*volatile downloadFirmware)(const char *, uint16_t *, const char *) = OTADownloadFirmware;
    int (*volatile applyFirmware)(int, uint16_t) = OTAApplyNewFirmware;
    OTAStagingStatus (*volatile getStatus)(void) = OTAStagingGetStatus;
    return downloadFirmware != NULL && applyFirmware != NULL &&
        getStatus != NULL;
}