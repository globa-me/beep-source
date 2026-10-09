#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct BSMonitor BSMonitor;
typedef struct {
    double start; // host uptime seconds, converted to wall time off the audio thread
    double end;
    float peak;
} BSFrame;
BSMonitor *BSMonitorCreate(AudioObjectID process, int32_t *error);
void BSMonitorDestroy(BSMonitor *monitor);
void BSMonitorStop(BSMonitor *monitor);
int BSMonitorDrain(BSMonitor *monitor, BSFrame *frames, int capacity);
uint64_t BSMonitorDropped(BSMonitor *monitor);
uint64_t BSMonitorCallbacks(BSMonitor *monitor);
double BSHostTime(void);
int BSProcessPath(int32_t pid, char *buffer, uint32_t size);
