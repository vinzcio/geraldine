#include "CThermal.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef CFTypeRef  (*CreateFn)(CFAllocatorRef);
typedef void       (*SetMatchingFn)(CFTypeRef, CFDictionaryRef);
typedef CFArrayRef (*CopyServicesFn)(CFTypeRef);
typedef CFStringRef(*CopyPropFn)(CFTypeRef, CFStringRef);
typedef CFTypeRef  (*CopyEventFn)(CFTypeRef, int64_t, int32_t, int64_t);
typedef double     (*GetFloatFn)(CFTypeRef, int32_t);

static int g_init = 0;
static CreateFn        g_create;
static SetMatchingFn   g_setMatching;
static CopyServicesFn  g_copyServices;
static CopyPropFn      g_copyProp;
static CopyEventFn     g_copyEvent;
static GetFloatFn      g_getFloat;

static void load_symbols(void) {
    if (g_init) return;
    g_init = 1;
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io) return;
    g_create       = (CreateFn)       dlsym(io, "IOHIDEventSystemClientCreate");
    g_setMatching  = (SetMatchingFn)  dlsym(io, "IOHIDEventSystemClientSetMatching");
    g_copyServices = (CopyServicesFn) dlsym(io, "IOHIDEventSystemClientCopyServices");
    g_copyProp     = (CopyPropFn)     dlsym(io, "IOHIDServiceClientCopyProperty");
    g_copyEvent    = (CopyEventFn)    dlsym(io, "IOHIDServiceClientCopyEvent");
    g_getFloat     = (GetFloatFn)     dlsym(io, "IOHIDEventGetFloatValue");
}

// Cached for the lifetime of the process. Creating an IOHIDEventSystemClient
// opens a connection to the system-wide HID event server — the same one that
// services the keyboard and mouse — so it must be reused, never recreated per
// sample (this is polled every second).
static CFTypeRef g_thermal_client = NULL;

static CFTypeRef thermal_client(void) {
    if (g_thermal_client) return g_thermal_client;

    int32_t page = 0xff00, usage = 5; // AppleVendor temperature sensors
    CFNumberRef pageN  = CFNumberCreate(0, kCFNumberSInt32Type, &page);
    CFNumberRef usageN = CFNumberCreate(0, kCFNumberSInt32Type, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageN, usageN };
    CFDictionaryRef match = CFDictionaryCreate(0, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFTypeRef client = g_create(kCFAllocatorDefault);
    if (client) {
        g_setMatching(client, match);
        g_thermal_client = client;
    }

    if (match)  CFRelease(match);
    if (pageN)  CFRelease(pageN);
    if (usageN) CFRelease(usageN);
    return g_thermal_client;
}

int thermal_read(double *temps, char *names, int nameStride, int maxCount) {
    load_symbols();
    if (!g_create || !g_setMatching || !g_copyServices || !g_copyEvent || !g_getFloat) return 0;

    CFTypeRef client = thermal_client();
    if (!client) return 0;

    CFArrayRef svcs = g_copyServices(client);
    if (!svcs) {
        // A NULL service list (as opposed to an empty one) means the connection
        // to the HID event server is gone; drop the client so the next sample
        // reconnects.
        CFRelease(g_thermal_client);
        g_thermal_client = NULL;
        return 0;
    }

    int count = 0;
    CFIndex n = CFArrayGetCount(svcs);
    for (CFIndex i = 0; i < n && count < maxCount; i++) {
        CFTypeRef s = CFArrayGetValueAtIndex(svcs, i);
        CFTypeRef ev = g_copyEvent(s, 15 /* kIOHIDEventTypeTemperature */, 0, 0);
        if (ev) {
            double t = g_getFloat(ev, 15 << 16 /* IOHIDEventFieldBase */);
            if (t > 1.0 && t < 150.0) {
                temps[count] = t;
                char *dst = names + (size_t)count * nameStride;
                dst[0] = '\0';
                if (g_copyProp) {
                    CFStringRef nm = g_copyProp(s, CFSTR("Product"));
                    if (nm) {
                        CFStringGetCString(nm, dst, nameStride, kCFStringEncodingUTF8);
                        CFRelease(nm);
                    }
                }
                count++;
            }
            CFRelease(ev);
        }
    }
    CFRelease(svcs);
    return count;
}

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

static uint32_t smc_fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) |
           ((uint32_t)(uint8_t)s[3]);
}

static void smc_fourcc_string(uint32_t value, char out[5]) {
    out[0] = (char)((value >> 24) & 0xff);
    out[1] = (char)((value >> 16) & 0xff);
    out[2] = (char)((value >> 8) & 0xff);
    out[3] = (char)(value & 0xff);
    out[4] = '\0';
}

static double smc_decode_temperature(const char type[5], const uint8_t *bytes, uint32_t size) {
    if (!strcmp(type, "sp78") && size >= 2) {
        int16_t raw = (int16_t)((bytes[0] << 8) | bytes[1]);
        return (double)raw / 256.0;
    }
    if (!strcmp(type, "fp88") && size >= 2) {
        uint16_t raw = (uint16_t)((bytes[0] << 8) | bytes[1]);
        return (double)raw / 256.0;
    }
    if (!strcmp(type, "fpe2") && size >= 2) {
        uint16_t raw = (uint16_t)((bytes[0] << 8) | bytes[1]);
        return (double)raw / 4.0;
    }
    if (!strcmp(type, "flt ") && size >= 4) {
        float native = 0;
        memcpy(&native, bytes, sizeof(native));
        return native;
    }
    return -1;
}

// Distinguish an unavailable key from a dead kernel connection. Missing keys
// are normal across Mac models; transport failures require reconnecting.
//  1 = temperature read, 0 = key unavailable/invalid, -1 = connection failed.
static int smc_read_key(io_connect_t conn, const char *key, double *temp) {
    SMCParamStruct input;
    SMCParamStruct output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));

    input.key = smc_fourcc(key);
    input.data8 = 9; // read key info
    size_t outputSize = sizeof(output);
    kern_return_t kr = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &outputSize);
    if (kr != KERN_SUCCESS) return -1;
    if (output.result != 0) return 0;

    input.keyInfo.dataSize = output.keyInfo.dataSize;
    input.keyInfo.dataType = output.keyInfo.dataType;
    input.keyInfo.dataAttributes = output.keyInfo.dataAttributes;
    input.data8 = 5; // read bytes
    memset(&output, 0, sizeof(output));
    outputSize = sizeof(output);
    kr = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &outputSize);
    if (kr != KERN_SUCCESS) return -1;
    if (output.result != 0) return 0;

    char type[5];
    smc_fourcc_string(input.keyInfo.dataType, type);
    double t = smc_decode_temperature(type, output.bytes, input.keyInfo.dataSize);
    if (t > 1.0 && t < 150.0) {
        *temp = t;
        return 1;
    }
    return 0;
}

static const char *const kCleanMyMacSMCTemperatureKeys[] = {
    "TC0D",
    "Tp00", "Tp01", "Tp02", "Tp04", "Tp05", "Tp06", "Tp08", "Tp09",
    "Tp0A", "Tp0a", "Tp0b", "Tp0c", "Tp0C", "Tp0D", "Tp0E", "Tp0f", "Tp0g",
    "Tp0G", "Tp0H", "Tp0I", "Tp0j", "Tp0k", "Tp0K", "Tp0L", "Tp0M", "Tp0O",
    "Tp0P", "Tp0Q", "Tp0S", "Tp0T", "Tp0U", "Tp0W", "Tp0X", "Tp0Y", "Tp17",
    "Tp18", "Tp1B", "Tp1C", "Tp1F", "Tp1G", "Tp1h", "Tp1i", "Tp1J", "Tp1K",
    "Tp1l", "Tp1m", "Tp1N", "Tp1O", "Tp1p", "Tp1q", "Tp1t", "Tp1u", "Tp2H",
    "Tp2I",
    "TC0P", "TCAD", "TC0H", "TC0F", "TCAH", "TCBH",
    "TCDX"
};

static size_t smc_temperature_key_count(void) {
    return sizeof(kCleanMyMacSMCTemperatureKeys) / sizeof(kCleanMyMacSMCTemperatureKeys[0]);
}

static void smc_write_sensor_name(char *names, int nameStride, int index, const char *key) {
    char *dst = names + (size_t)index * nameStride;
    snprintf(dst, (size_t)nameStride, "SMC %s", key);
}

// Kept open for the lifetime of the process: opening and closing an AppleSMC
// user client every sample (this is polled every second) churns the kernel
// service with connect–disconnect traffic for no benefit.
static io_connect_t g_smc_conn = IO_OBJECT_NULL;

static void smc_invalidate_connection(void) {
    if (g_smc_conn == IO_OBJECT_NULL) return;
    IOServiceClose(g_smc_conn);
    g_smc_conn = IO_OBJECT_NULL;
}

static io_connect_t smc_connection(void) {
    if (g_smc_conn != IO_OBJECT_NULL) return g_smc_conn;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return IO_OBJECT_NULL;

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    g_smc_conn = conn;
    return conn;
}

int smc_thermal_read(double *temps, char *names, int nameStride, int maxCount) {
    io_connect_t conn = smc_connection();
    if (conn == IO_OBJECT_NULL) return 0;

    int count = 0;
    for (size_t i = 0; i < smc_temperature_key_count() && count < maxCount; i++) {
        const char *key = kCleanMyMacSMCTemperatureKeys[i];
        double t = 0;
        int status = smc_read_key(conn, key, &t);
        if (status < 0) {
            // Sleep/wake and AppleSMC service restarts can invalidate an open
            // user client. The next sample will establish a fresh connection.
            smc_invalidate_connection();
            return count;
        }
        if (status > 0) {
            temps[count] = t;
            smc_write_sensor_name(names, nameStride, count, key);
            count++;
        }
    }

    return count;
}
