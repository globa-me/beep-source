#import "AudioMeter.h"
#import <Foundation/Foundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <libproc.h>

#define BS_CAPACITY 2048
struct BSMonitor {
    AudioObjectID tap, device;
    AudioDeviceIOProcID proc;
    double hostScale, sampleRate;
    BSFrame frames[BS_CAPACITY];
    _Atomic uint32_t readIndex, writeIndex;
    _Atomic uint64_t dropped, callbacks;
    bool stopped;
};
static double hostScale(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return (double)info.numer / info.denom / 1e9;
}
double BSHostTime(void) { return mach_absolute_time() * hostScale(); }
int BSProcessPath(int32_t pid, char *buffer, uint32_t size) { return proc_pidpath(pid, buffer, size); }

// The IO thread performs only arithmetic and lock-free SPSC writes. No dispatch,
// allocation, logging, files, Swift/ObjC calls or application lookups here.
static OSStatus meter(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *client) {
    BSMonitor *m = client;
    atomic_fetch_add_explicit(&m->callbacks, 1, memory_order_relaxed);
    float peak = 0;
    uint32_t first = UINT32_MAX, last = 0;
    const float threshold = 0.0005623413f; // -65 dBFS
    for (UInt32 b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buf = &input->mBuffers[b];
        if (!buf->mData || !buf->mNumberChannels) continue;
        const float *samples = buf->mData;
        UInt32 count = buf->mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < count; ++i) {
            float value = fabsf(samples[i]);
            if (!isfinite(value)) continue;
            if (value > peak) peak = value;
            if (value >= threshold) {
                UInt32 frame = i / buf->mNumberChannels;
                if (frame < first) first = frame;
                if (frame > last) last = frame;
            }
        }
    }
    if (first != UINT32_MAX) {
        double base = ((inputTime->mFlags & kAudioTimeStampHostTimeValid)
            ? inputTime->mHostTime : mach_absolute_time()) * m->hostScale;
        BSFrame frame = { base + first / m->sampleRate,
            base + (last + 1) / m->sampleRate, peak };
        uint32_t write = atomic_load_explicit(&m->writeIndex, memory_order_relaxed);
        uint32_t next = (write + 1) % BS_CAPACITY;
        if (next != atomic_load_explicit(&m->readIndex, memory_order_acquire)) {
            m->frames[write] = frame;
            atomic_store_explicit(&m->writeIndex, next, memory_order_release);
        } else atomic_fetch_add_explicit(&m->dropped, 1, memory_order_relaxed);
    }
    return noErr;
}

BSMonitor *BSMonitorCreate(AudioObjectID process, int32_t *error) {
    BSMonitor *m = calloc(1, sizeof(BSMonitor));
    if (!m) { *error = -108; return NULL; }
    m->hostScale = hostScale();
    // Zero denotes the global safety net. This application never produces audio.
    CATapDescription *description = process ? [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(process)]]
        : [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @"Beep Source meter";
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    NSDictionary *composition = nil;
    OSStatus status = AudioHardwareCreateProcessTap(description, &m->tap);
    if (status != noErr) goto failed;
    AudioStreamBasicDescription format = {0};
    AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(format);
    status = AudioObjectGetPropertyData(m->tap, &address, 0, NULL, &size, &format);
    if (status != noErr) goto failed;
    if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat)
        || format.mBitsPerChannel != 32 || format.mSampleRate <= 0) {
        status = kAudioDeviceUnsupportedFormatError; goto failed;
    }
    m->sampleRate = format.mSampleRate;
    composition = @{
        @kAudioAggregateDeviceNameKey: @"Beep Source private meter",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES
        }]
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &m->device);
    if (status != noErr) goto failed;
    status = AudioDeviceCreateIOProcID(m->device, meter, m, &m->proc);
    if (status != noErr) goto failed;
    status = AudioDeviceStart(m->device, m->proc);
    if (status != noErr) goto failed;
    *error = noErr;
    return m;
failed:
    *error = status;
    BSMonitorDestroy(m);
    return NULL;
}
void BSMonitorDestroy(BSMonitor *m) {
    if (!m) return;
    if (m->proc) {
        BSMonitorStop(m);
        AudioDeviceDestroyIOProcID(m->device, m->proc);
    }
    if (m->device) AudioHardwareDestroyAggregateDevice(m->device);
    if (m->tap) AudioHardwareDestroyProcessTap(m->tap);
    free(m);
}
void BSMonitorStop(BSMonitor *m) {
    if (m && m->proc && !m->stopped) { AudioDeviceStop(m->device, m->proc); m->stopped = true; }
}
int BSMonitorDrain(BSMonitor *m, BSFrame *frames, int capacity) {
    uint32_t read = atomic_load_explicit(&m->readIndex, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&m->writeIndex, memory_order_acquire);
    int count = 0;
    while (read != write && count < capacity) {
        frames[count++] = m->frames[read];
        read = (read + 1) % BS_CAPACITY;
    }
    atomic_store_explicit(&m->readIndex, read, memory_order_release);
    return count;
}
uint64_t BSMonitorDropped(BSMonitor *m) { return atomic_load_explicit(&m->dropped, memory_order_relaxed); }
uint64_t BSMonitorCallbacks(BSMonitor *m) { return atomic_load_explicit(&m->callbacks, memory_order_relaxed); }
