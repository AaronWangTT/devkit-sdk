#ifndef CONFIGURATION_PROVIDER_H
#define CONFIGURATION_PROVIDER_H

#include <stddef.h>

struct ConfigurationCommand
{
    const char *name;
    const char *help;
    bool isPrivacy;
    void (*function)(int argc, char **argv);
};

struct ConfigurationForm
{
    void *context;
    int (*read)(void *context, const char *name, char *value, size_t capacity);
};

const ConfigurationCommand *GetConfigurationCommands(size_t *count);
int WriteConfigurationForm(int options, char *destination, size_t capacity);
size_t GetConfigurationBodySize(int options);
int ReadConfigurationSettings(int options, const ConfigurationForm *form, void **settings);
int SaveConfigurationSettings(void *settings, char *destination, size_t capacity);
void FreeConfigurationSettings(void *settings);

inline size_t GetConfigurationRequestCapacity(int options, size_t standardValueBytes)
{
    return 2048 + 3 * (standardValueBytes + GetConfigurationBodySize(options));
}

#endif