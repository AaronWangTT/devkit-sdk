#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <string>

#include "../../src/cores/arduino/WString.h"
#include "parson.h"

#define Arduino_h
#define __HTTP_CLIENT_H__
#define SASTOKEN_H

class FakeSerial {
public:
    template <typename Value>
    void print(const Value &) {}

    template <typename Value>
    void println(const Value &) {}
};

FakeSerial Serial;

enum http_method { HTTP_GET, HTTP_PUT, HTTP_POST, HTTP_DELETE };

struct KEYVALUE {
    const char *key;
    const char *value;
    KEYVALUE *prev;
};

struct Http_Response {
    int status_code;
    int body_length;
    const char *status_message;
    const char *body;
    const KEYVALUE *headers;
};

const Http_Response *nextResponse = NULL;
int requestCount = 0;

class HTTPClient {
public:
    HTTPClient(http_method, const char *) {}
    void set_header(const char *, const char *) {}

    const Http_Response *send(const void * = NULL, int = 0) {
        ++requestCount;
        return nextResponse;
    }
};

typedef const char *STRING_HANDLE;

STRING_HANDLE STRING_construct(const char *value) { return value; }
STRING_HANDLE STRING_new() { return ""; }
STRING_HANDLE SASToken_Create(STRING_HANDLE, STRING_HANDLE, STRING_HANDLE, size_t) {
    return "test-token";
}
const char *STRING_c_str(STRING_HANDLE value) { return value; }
size_t STRING_length(STRING_HANDLE value) { return std::strlen(value); }
void STRING_delete(STRING_HANDLE) {}

const std::time_t TestTime = 1500000000;
std::time_t fakeTime(std::time_t *) { return TestTime; }

struct json_object_t {
    std::map<std::string, std::string> fields;
};

struct json_value_t {
    JSON_Value_Type type;
    JSON_Object *object;
};

JSON_Value *nextParsedValue = NULL;
int parseCount = 0;
int jsonFreeCount = 0;

JSON_Value *json_parse_string(const char *) {
    ++parseCount;
    return nextParsedValue;
}

JSON_Object *json_value_get_object(const JSON_Value *value) {
    return value != NULL && value->type == JSONObject ? value->object : NULL;
}

const char *json_object_get_string(const JSON_Object *object, const char *name) {
    const auto field = object->fields.find(name);
    return field == object->fields.end() ? NULL : field->second.c_str();
}

void json_value_free(JSON_Value *value) {
    ++jsonFreeCount;
    if (value->type == JSONObject) {
        value->object->fields.clear();
    }
}

#define time fakeTime
#pragma GCC diagnostic push
#pragma GCC diagnostic warning "-Wunused-variable"
#pragma GCC diagnostic warning "-Wsign-compare"
#include "examples/VoiceToTwitter/iot_client.cpp"
#pragma GCC diagnostic pop
#undef time

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "%s:%d: requirement failed: %s\n", __FILE__, __LINE__, #condition); \
            return false; \
        } \
    } while (0)

struct UploadFixture {
    JSON_Object object;
    JSON_Value value;
    Http_Response response;

    UploadFixture() : value{JSONObject, &object}, response{200, 2, "OK", "{}", NULL} {
        object.fields["correlationId"] = "test-correlation";
        object.fields["hostName"] = "upload.example";
        object.fields["containerName"] = "container";
        object.fields["blobName"] = "voice.wav";
        object.fields["sasToken"] = "?sig=test";
        nextParsedValue = &value;
        nextResponse = &response;
        requestCount = 0;
        parseCount = 0;
        jsonFreeCount = 0;
        _setString(&hostNameString, "hub.example", std::strlen("hub.example"));
        _setString(&deviceIdString, "test-device", std::strlen("test-device"));
        _setString(&deviceKeyString, "test-key", std::strlen("test-key"));
        _setString(&current_token, "test-token", std::strlen("test-token"));
        current_expiry = static_cast<size_t>(TestTime) + 3600;
    }

    ~UploadFixture() {
        char **strings[] = {
            &hostNameString, &deviceIdString, &deviceKeyString,
            &current_token, &sasUri, &correlationId
        };
        for (size_t index = 0; index < sizeof(strings) / sizeof(strings[0]); ++index) {
            std::free(*strings[index]);
            *strings[index] = NULL;
        }
        current_expiry = 0;
        nextParsedValue = NULL;
        nextResponse = NULL;
    }
};

bool validObjectCopiesUploadDetails() {
    UploadFixture fixture;
    REQUIRE(iot_client_blob_upload_step1("voice.wav") == 0);
    REQUIRE(sasUri != NULL);
    REQUIRE(correlationId != NULL);
    REQUIRE(std::strcmp(sasUri, "https://upload.example/container/voice.wav?sig=test") == 0);
    REQUIRE(std::strcmp(correlationId, "test-correlation") == 0);
    REQUIRE(requestCount == 1);
    REQUIRE(parseCount == 1);
    REQUIRE(jsonFreeCount == 1);
    REQUIRE(fixture.object.fields.empty());
    return true;
}

bool parseFailureIsReported() {
    UploadFixture fixture;
    nextParsedValue = NULL;
    REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
    REQUIRE(sasUri == NULL);
    REQUIRE(correlationId == NULL);
    REQUIRE(parseCount == 1);
    REQUIRE(jsonFreeCount == 0);
    return true;
}

bool nonObjectRootsAreRejected() {
    const JSON_Value_Type types[] = {JSONNull, JSONArray, JSONString, JSONNumber, JSONBoolean};
    for (size_t index = 0; index < sizeof(types) / sizeof(types[0]); ++index) {
        UploadFixture fixture;
        fixture.value.type = types[index];
        REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
        REQUIRE(sasUri == NULL);
        REQUIRE(correlationId == NULL);
        REQUIRE(jsonFreeCount == 1);
    }
    return true;
}

bool missingRequiredStringsAreRejected() {
    const char *fields[] = {"correlationId", "hostName", "containerName", "blobName", "sasToken"};
    for (size_t index = 0; index < sizeof(fields) / sizeof(fields[0]); ++index) {
        UploadFixture fixture;
        fixture.object.fields.erase(fields[index]);
        REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
        REQUIRE(sasUri == NULL);
        REQUIRE(correlationId == NULL);
        REQUIRE(jsonFreeCount == 1);
    }
    return true;
}

bool invalidResponseAfterSuccessIsReported() {
    UploadFixture fixture;
    REQUIRE(iot_client_blob_upload_step1("voice.wav") == 0);
    fixture.value.type = JSONArray;
    REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
    REQUIRE(jsonFreeCount == 2);
    return true;
}

bool missingHttpResponseIsReported() {
    UploadFixture fixture;
    nextResponse = NULL;
    REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
    REQUIRE(parseCount == 0);
    REQUIRE(jsonFreeCount == 0);
    return true;
}

bool unsuccessfulHttpStatusesAreRejected() {
    const int statuses[] = {199, 300, 400, 500};
    for (size_t index = 0; index < sizeof(statuses) / sizeof(statuses[0]); ++index) {
        UploadFixture fixture;
        fixture.response.status_code = statuses[index];
        REQUIRE(iot_client_blob_upload_step1("voice.wav") == -1);
        REQUIRE(sasUri == NULL);
        REQUIRE(correlationId == NULL);
        REQUIRE(parseCount == 0);
        REQUIRE(jsonFreeCount == 0);
    }
    return true;
}

struct TestCase {
    const char *name;
    bool (*run)();
};

int main() {
    const TestCase tests[] = {
        {"valid object copies upload details", validObjectCopiesUploadDetails},
        {"parse failure is reported", parseFailureIsReported},
        {"non-object roots are rejected", nonObjectRootsAreRejected},
        {"missing required strings are rejected", missingRequiredStringsAreRejected},
        {"invalid response after success is reported", invalidResponseAfterSuccessIsReported},
        {"missing HTTP response is reported", missingHttpResponseIsReported},
        {"unsuccessful HTTP statuses are rejected", unsuccessfulHttpStatusesAreRejected}
    };
    int failures = 0;
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        const bool passed = tests[index].run();
        std::printf("%s %s\n", passed ? "PASS" : "FAIL", tests[index].name);
        if (!passed) {
            ++failures;
        }
    }
    std::printf("%zu tests, %d failures\n", sizeof(tests) / sizeof(tests[0]), failures);
    return failures == 0 ? 0 : 1;
}