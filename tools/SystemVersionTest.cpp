#include <cstdint>
#include <cstdio>
#include <cstring>

#include "SystemVersion.h"

int main(int argumentCount, char **arguments) {
    if (argumentCount != 2) {
        std::fprintf(stderr, "expected one version argument\n");
        return 1;
    }

    unsigned int expectedMajor = 0;
    unsigned int expectedMinor = 0;
    unsigned int expectedPatch = 0;
    char trailing = '\0';
    if (std::sscanf(
            arguments[1],
            "%u.%u.%u%c",
            &expectedMajor,
            &expectedMinor,
            &expectedPatch,
            &trailing) != 3) {
        std::fprintf(stderr, "invalid expected version: %s\n", arguments[1]);
        return 1;
    }

    if (std::strcmp(getDevkitVersion(), arguments[1]) != 0) {
        std::fprintf(
            stderr,
            "getDevkitVersion returned %s instead of %s\n",
            getDevkitVersion(),
            arguments[1]);
        return 1;
    }
    if (
        getMajorVersion() != expectedMajor ||
        getMinorVersion() != expectedMinor ||
        getPatchVersion() != expectedPatch
    ) {
        std::fprintf(stderr, "numeric version accessors do not match %s\n", arguments[1]);
        return 1;
    }

    return 0;
}