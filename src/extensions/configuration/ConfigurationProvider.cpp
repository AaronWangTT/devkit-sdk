#include "ConfigurationProvider.h"

const ConfigurationCommand *GetConfigurationCommands(size_t *count)
{
    *count = 0;
    return NULL;
}

int WriteConfigurationForm(int, char *destination, size_t capacity)
{
    if (capacity > 0) { destination[0] = '\0'; }
    return 0;
}

size_t GetConfigurationBodySize(int)
{
    return 0;
}

int ReadConfigurationSettings(int, const ConfigurationForm *, void **settings)
{
    *settings = NULL;
    return 0;
}

int SaveConfigurationSettings(void *, char *destination, size_t capacity)
{
    if (capacity > 0) { destination[0] = '\0'; }
    return 0;
}

void FreeConfigurationSettings(void *)
{
}