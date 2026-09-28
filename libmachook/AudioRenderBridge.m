#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include "interpose.h"
#include "macws_audio_bridge.h"

typedef OSStatus (*MacWSAudioUnitSetPropertyFn)(
    AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
    const void *, UInt32);
typedef OSStatus (*MacWSAudioUnitGetPropertyFn)(
    AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
    void *, UInt32 *);
typedef OSStatus (*MacWSAudioOutputUnitStartFn)(AudioUnit);
typedef OSStatus (*MacWSAudioOutputUnitStopFn)(AudioUnit);
typedef OSStatus (*MacWSAudioComponentInstanceDisposeFn)(AudioComponentInstance);

typedef struct MacWSAudioRenderContext {
    AURenderCallback original;
    void *originalContext;
    AudioUnit unit;
    AudioStreamBasicDescription format;
    MacWSAudioRingHeader *ring;
    uint64_t producerToken;
    _Atomic(bool) softwareCadenceRunning;
    bool softwareCadenceThreadCreated;
    pthread_t softwareCadenceThread;
    struct MacWSAudioRenderContext *next;
    int16_t scratch[4096 * MACWS_AUDIO_CHANNELS];
} MacWSAudioRenderContext;

static MacWSAudioUnitSetPropertyFn gMacWSOriginalAudioUnitSetProperty;
static MacWSAudioUnitGetPropertyFn gMacWSAudioUnitGetProperty;
static MacWSAudioOutputUnitStartFn gMacWSOriginalAudioOutputUnitStart;
static MacWSAudioOutputUnitStopFn gMacWSOriginalAudioOutputUnitStop;
static MacWSAudioComponentInstanceDisposeFn
    gMacWSOriginalAudioComponentInstanceDispose;
static pthread_once_t gMacWSAudioSymbolsOnce = PTHREAD_ONCE_INIT;
static _Atomic(uint32_t) gMacWSAudioProducerSerial = 1;
static uint64_t gMacWSAudioOwnerSilenceTicks;
static pthread_mutex_t gMacWSAudioContextsLock = PTHREAD_MUTEX_INITIALIZER;
static MacWSAudioRenderContext *gMacWSAudioContexts;
static _Atomic(int) gMacWSSoftwareCadenceMode = -1;

static void MacWSResolveAudioSymbols(void) {
    // These entry points live in the Ventura shared cache.  Inline-hooking
    // them with MSHookFunction asks Substrate to discover a function's length
    // by reading forward through instructions.  Runtime-confirmed on the M1
    // iPad13,11 cache: AudioUnitSetProperty is adjacent to an unreadable cache
    // page, so Substrate's findFunctionSize crossed that boundary and SIGBUS'd
    // every utility process which happened to load AudioToolbox (including
    // /usr/bin/codesign).  Resolve the un-interposed implementations through
    // RTLD_NEXT and let dyld's supported __interpose mechanism redirect calls;
    // no shared-cache text is scanned or modified.
    gMacWSOriginalAudioUnitSetProperty = (MacWSAudioUnitSetPropertyFn)
        dlsym(RTLD_NEXT, "AudioUnitSetProperty");
    gMacWSAudioUnitGetProperty = (MacWSAudioUnitGetPropertyFn)
        dlsym(RTLD_NEXT, "AudioUnitGetProperty");
    gMacWSOriginalAudioOutputUnitStart = (MacWSAudioOutputUnitStartFn)
        dlsym(RTLD_NEXT, "AudioOutputUnitStart");
    gMacWSOriginalAudioOutputUnitStop = (MacWSAudioOutputUnitStopFn)
        dlsym(RTLD_NEXT, "AudioOutputUnitStop");
    gMacWSOriginalAudioComponentInstanceDispose =
        (MacWSAudioComponentInstanceDisposeFn)
            dlsym(RTLD_NEXT, "AudioComponentInstanceDispose");
}

static void MacWSEnsureAudioSymbols(void) {
    pthread_once(&gMacWSAudioSymbolsOnce, MacWSResolveAudioSymbols);
}

static BOOL MacWSAudioBridgeProcessEligible(void) {
    const char *program = getprogname();
    return !(program && (strcmp(program, "coreaudiod") == 0 ||
                         strcmp(program, "AudioComponentRegistrar") == 0));
}

static BOOL MacWSNeedsSoftwareAudioCadence(void) {
    int cached = atomic_load_explicit(&gMacWSSoftwareCadenceMode,
                                      memory_order_acquire);
    if (cached >= 0) return cached != 0;
    char machine[64] = {0};
    size_t length = sizeof(machine);
    BOOL enabled = sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 &&
        strcmp(machine, "iPad14,5") == 0;
    int expected = -1;
    if (atomic_compare_exchange_strong_explicit(
            &gMacWSSoftwareCadenceMode, &expected, enabled ? 1 : 0,
            memory_order_acq_rel, memory_order_acquire)) {
        fprintf(stderr,
                "#### MACWS-AUDIO cadence=%s machine=%s\n",
                enabled ? "software" : "hal",
                machine[0] ? machine : "<unknown>");
    }
    return atomic_load_explicit(&gMacWSSoftwareCadenceMode,
                                memory_order_acquire) != 0;
}

static MacWSAudioRenderContext *MacWSFindAudioContext(AudioUnit unit) {
    MacWSAudioRenderContext *match = NULL;
    pthread_mutex_lock(&gMacWSAudioContextsLock);
    for (MacWSAudioRenderContext *context = gMacWSAudioContexts;
         context; context = context->next) {
        if (context->unit == unit) {
            match = context;
            break;
        }
    }
    pthread_mutex_unlock(&gMacWSAudioContextsLock);
    return match;
}

static void MacWSRegisterAudioContext(MacWSAudioRenderContext *context) {
    if (!context) return;
    pthread_mutex_lock(&gMacWSAudioContextsLock);
    context->next = gMacWSAudioContexts;
    gMacWSAudioContexts = context;
    pthread_mutex_unlock(&gMacWSAudioContextsLock);
}

static void MacWSUnregisterAudioContext(MacWSAudioRenderContext *context) {
    if (!context) return;
    pthread_mutex_lock(&gMacWSAudioContextsLock);
    MacWSAudioRenderContext **cursor = &gMacWSAudioContexts;
    while (*cursor && *cursor != context) cursor = &(*cursor)->next;
    if (*cursor == context) *cursor = context->next;
    context->next = NULL;
    pthread_mutex_unlock(&gMacWSAudioContextsLock);
}

static BOOL MacWSAudioContextOwnsRing(MacWSAudioRenderContext *context,
                                     uint16_t peak,
                                     uint64_t now) {
    if (!context || !context->ring || !context->producerToken) return NO;
    MacWSAudioRingHeader *header = context->ring;
    uint64_t owner = __atomic_load_n(
        &header->reserved[MACWS_AUDIO_RESERVED_OWNER_TOKEN],
        __ATOMIC_ACQUIRE);
    if (owner == context->producerToken) {
        if (peak >= 8) {
            __atomic_store_n(
                &header->reserved[MACWS_AUDIO_RESERVED_OWNER_LAST_AUDIBLE],
                now, __ATOMIC_RELEASE);
        }
        return YES;
    }
    // A context cannot take ownership before it has real signal. This keeps
    // Chromium's dormant/silent AudioUnits from interleaving zero blocks with
    // the active YouTube stream.
    if (peak < 8) return NO;
    uint64_t lastAudible = __atomic_load_n(
        &header->reserved[MACWS_AUDIO_RESERVED_OWNER_LAST_AUDIBLE],
        __ATOMIC_ACQUIRE);
    if (owner != 0 && lastAudible != 0 && now > lastAudible &&
        now - lastAudible <= gMacWSAudioOwnerSilenceTicks)
        return NO;
    uint64_t expected = owner;
    if (!__atomic_compare_exchange_n(
            &header->reserved[MACWS_AUDIO_RESERVED_OWNER_TOKEN],
            &expected, context->producerToken, false,
            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        return expected == context->producerToken;
    __atomic_store_n(
        &header->reserved[MACWS_AUDIO_RESERVED_OWNER_LAST_AUDIBLE],
        now, __ATOMIC_RELEASE);
    return YES;
}

static MacWSAudioRingHeader *MacWSMapAudioRing(void) {
    int descriptor = open(MACWS_AUDIO_RING_CHROOT_PATH,
                          O_RDWR | O_CLOEXEC);
    if (descriptor < 0) return NULL;
    const size_t bytes = (size_t)MacWSAudioRingBytes(
        MACWS_AUDIO_RING_CAPACITY_FRAMES);
    void *mapping = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                         MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) return NULL;
    MacWSAudioRingHeader *header = mapping;
    if (__atomic_load_n(&header->magic, __ATOMIC_ACQUIRE) !=
            MACWS_AUDIO_RING_MAGIC ||
        header->version != MACWS_AUDIO_RING_VERSION ||
        header->sampleRate != MACWS_AUDIO_SAMPLE_RATE ||
        header->channels != MACWS_AUDIO_CHANNELS ||
        header->capacityFrames != MACWS_AUDIO_RING_CAPACITY_FRAMES) {
        munmap(mapping, bytes);
        return NULL;
    }
    return header;
}

static float MacWSReadAudioSample(const AudioBufferList *buffers,
                                  const AudioStreamBasicDescription *format,
                                  UInt32 frame, UInt32 channel) {
    if (!buffers || !format || buffers->mNumberBuffers == 0) return 0.0f;
    const bool nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 bufferIndex = nonInterleaved &&
            channel < buffers->mNumberBuffers ? channel : 0;
    const AudioBuffer *buffer = &buffers->mBuffers[bufferIndex];
    if (!buffer->mData) return 0.0f;
    const UInt32 channels = nonInterleaved ? 1 :
        (format->mChannelsPerFrame ?: buffer->mNumberChannels ?: 1);
    const UInt64 sampleIndex = (UInt64)frame * channels +
        (nonInterleaved ? 0 : channel % channels);
    const UInt32 bytesPerSample = format->mBitsPerChannel / 8;
    if (bytesPerSample == 0 ||
        (sampleIndex + 1) * bytesPerSample > buffer->mDataByteSize)
        return 0.0f;
    const uint8_t *source = buffer->mData;
    if ((format->mFormatFlags & kAudioFormatFlagIsFloat) &&
        format->mBitsPerChannel == 32) {
        return ((const float *)source)[sampleIndex];
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
        format->mBitsPerChannel == 16) {
        return ((const int16_t *)source)[sampleIndex] / 32768.0f;
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
        format->mBitsPerChannel == 32) {
        return ((const int32_t *)source)[sampleIndex] / 2147483648.0f;
    }
    return 0.0f;
}

static void MacWSPublishAudio(MacWSAudioRenderContext *context,
                              const AudioBufferList *buffers,
                              UInt32 sourceFrames) {
    if (!context || !buffers || sourceFrames == 0 ||
        context->format.mFormatID != kAudioFormatLinearPCM)
        return;
    if (!context->ring) context->ring = MacWSMapAudioRing();
    MacWSAudioRingHeader *header = context->ring;
    if (!header) return;

    double sourceRate = context->format.mSampleRate;
    if (sourceRate < 1.0) sourceRate = MACWS_AUDIO_SAMPLE_RATE;
    UInt32 outputFrames = (UInt32)(
        sourceFrames * (double)MACWS_AUDIO_SAMPLE_RATE / sourceRate + 0.5);
    if (outputFrames > 4096) outputFrames = 4096;
    uint16_t peak = 0;
    for (UInt32 outputFrame = 0; outputFrame < outputFrames; outputFrame++) {
        UInt32 sourceFrame = (UInt32)(
            outputFrame * sourceRate / (double)MACWS_AUDIO_SAMPLE_RATE);
        if (sourceFrame >= sourceFrames) sourceFrame = sourceFrames - 1;
        for (UInt32 channel = 0; channel < MACWS_AUDIO_CHANNELS; channel++) {
            UInt32 sourceChannel = context->format.mChannelsPerFrame > 1
                ? channel : 0;
            float value = MacWSReadAudioSample(
                buffers, &context->format, sourceFrame, sourceChannel);
            if (value > 1.0f) value = 1.0f;
            if (value < -1.0f) value = -1.0f;
            int16_t converted = (int16_t)(value * 32767.0f);
            context->scratch[outputFrame * MACWS_AUDIO_CHANNELS + channel] =
                converted;
            uint16_t magnitude = converted == INT16_MIN ? 32768 :
                (uint16_t)(converted < 0 ? -converted : converted);
            if (magnitude > peak) peak = magnitude;
        }
    }

    uint64_t now = mach_continuous_time();
    if (!MacWSAudioContextOwnsRing(context, peak, now)) return;

    // Audio render callbacks must never wait behind another process. Drop a
    // single quantum on contention; the next callback arrives in a few ms.
    if (__atomic_exchange_n(
            &header->reserved[MACWS_AUDIO_RESERVED_WRITER_LOCK], 1,
            __ATOMIC_ACQUIRE) != 0)
        return;

    const uint64_t capacity = header->capacityFrames;
    uint64_t writeFrame = __atomic_load_n(
        &header->writeFrame, __ATOMIC_RELAXED);
    uint64_t offset = writeFrame % capacity;
    uint64_t firstFrames = capacity - offset;
    if (firstFrames > outputFrames) firstFrames = outputFrames;
    int16_t *ringSamples = (int16_t *)(header + 1);
    size_t firstSamples = (size_t)firstFrames * MACWS_AUDIO_CHANNELS;
    memcpy(ringSamples + offset * MACWS_AUDIO_CHANNELS, context->scratch,
           firstSamples * sizeof(*ringSamples));
    UInt32 remaining = outputFrames - (UInt32)firstFrames;
    if (remaining) {
        memcpy(ringSamples, context->scratch + firstSamples,
               (size_t)remaining * MACWS_AUDIO_CHANNELS *
                   sizeof(*ringSamples));
    }
    if (peak >= 8) {
        __atomic_store_n(&header->lastAudibleMachTime,
                         now, __ATOMIC_RELEASE);
    }
    __atomic_add_fetch(&header->callbackCount, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&header->writeFrame, writeFrame + outputFrames,
                     __ATOMIC_RELEASE);
    __atomic_store_n(
        &header->reserved[MACWS_AUDIO_RESERVED_WRITER_LOCK], 0,
        __ATOMIC_RELEASE);
}

static OSStatus MacWSAudioRenderCallback(
        void *reference, AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
        AudioBufferList *buffers) {
    MacWSAudioRenderContext *context = reference;
    OSStatus status = context && context->original
        ? context->original(context->originalContext, flags, timestamp, bus,
                            frames, buffers)
        : kAudio_ParamError;
    if (status == noErr && buffers) MacWSPublishAudio(context, buffers, frames);
    return status;
}

static AudioBufferList *MacWSCreateSoftwareAudioBuffers(
        const AudioStreamBasicDescription *format, UInt32 frames) {
    if (!format || !frames || format->mChannelsPerFrame == 0 ||
        format->mChannelsPerFrame > 32)
        return NULL;
    BOOL nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bufferCount = nonInterleaved ? format->mChannelsPerFrame : 1;
    size_t listBytes = offsetof(AudioBufferList, mBuffers) +
        (size_t)bufferCount * sizeof(AudioBuffer);
    AudioBufferList *buffers = calloc(1, listBytes);
    if (!buffers) return NULL;
    UInt32 bytesPerBuffer = frames * format->mBytesPerFrame;
    if (bytesPerBuffer == 0) {
        UInt32 bytesPerSample = format->mBitsPerChannel / 8;
        bytesPerBuffer = frames * bytesPerSample *
            (nonInterleaved ? 1 : format->mChannelsPerFrame);
    }
    if (bytesPerBuffer == 0) {
        free(buffers);
        return NULL;
    }
    buffers->mNumberBuffers = bufferCount;
    for (UInt32 index = 0; index < bufferCount; index++) {
        buffers->mBuffers[index].mNumberChannels = nonInterleaved
            ? 1 : format->mChannelsPerFrame;
        buffers->mBuffers[index].mDataByteSize = bytesPerBuffer;
        buffers->mBuffers[index].mData = calloc(1, bytesPerBuffer);
        if (!buffers->mBuffers[index].mData) {
            for (UInt32 previous = 0; previous < index; previous++)
                free(buffers->mBuffers[previous].mData);
            free(buffers);
            return NULL;
        }
    }
    return buffers;
}

static void MacWSDestroySoftwareAudioBuffers(AudioBufferList *buffers) {
    if (!buffers) return;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; index++)
        free(buffers->mBuffers[index].mData);
    free(buffers);
}

static void *MacWSSoftwareAudioCadenceMain(void *reference) {
    MacWSAudioRenderContext *context = reference;
    pthread_setname_np("macws.audio.cadence");
    const UInt32 frames = 512;
    AudioBufferList *buffers = MacWSCreateSoftwareAudioBuffers(
        &context->format, frames);
    if (!buffers) {
        atomic_store_explicit(&context->softwareCadenceRunning, false,
                              memory_order_release);
        return NULL;
    }
    double sampleRate = context->format.mSampleRate;
    if (sampleRate < 1.0) sampleRate = MACWS_AUDIO_SAMPLE_RATE;
    uint64_t quantumNanoseconds = (uint64_t)(
        (long double)frames * 1000000000.0L / sampleRate);
    if (quantumNanoseconds == 0) quantumNanoseconds = 1;
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
        timebase.numer == 0 || timebase.denom == 0) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    uint64_t quantumTicks = (uint64_t)(
        (long double)quantumNanoseconds * timebase.denom / timebase.numer);
    if (quantumTicks == 0) quantumTicks = 1;
    uint64_t nextDeadline = mach_absolute_time();
    Float64 sampleTime = 0;
    unsigned failures = 0;
    while (atomic_load_explicit(&context->softwareCadenceRunning,
                                memory_order_acquire)) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; index++) {
            memset(buffers->mBuffers[index].mData, 0,
                   buffers->mBuffers[index].mDataByteSize);
        }
        AudioTimeStamp timestamp = {
            .mSampleTime = sampleTime,
            .mHostTime = mach_absolute_time(),
            .mFlags = kAudioTimeStampSampleTimeValid |
                      kAudioTimeStampHostTimeValid,
        };
        AudioUnitRenderActionFlags flags = 0;
        OSStatus status = context->original
            ? context->original(context->originalContext, &flags, &timestamp,
                                0, frames, buffers)
            : kAudio_ParamError;
        if (status == noErr) {
            MacWSPublishAudio(context, buffers, frames);
        } else if (failures++ < 3) {
            fprintf(stderr,
                    "#### MACWS-AUDIO software callback status=%d unit=%p\n",
                    (int)status, context->unit);
        }
        sampleTime += frames;
        // mach_wait_until from the Ventura libsystem does not share the same
        // deadline epoch with the iOS 16.0 kernel on this device: a runtime
        // sample caught the cadence thread parked in that trap for 13+ s.
        // Relative POSIX sleep crosses the chroot boundary correctly, but the
        // old loop slept a full quantum *after* doing the render work. Runtime
        // evidence on iPad14,5 was:
        //   AUDIO-RATE elapsed=5.005408 write_delta=202240
        //   producer_fps=40404.295 callback_delta=395 callback_hz=78.915
        //   underrun_delta=91 owner_pid=39125
        // Accumulate the intended absolute schedule in mach ticks, then use
        // only a relative nanosleep for the remaining interval. This keeps
        // callback execution time out of the 48-kHz cadence without entering
        // the incompatible mach_wait_until trap. A long scheduler stall is
        // bounded to eight catch-up quanta instead of producing an unbounded
        // callback burst.
        nextDeadline += quantumTicks;
        for (;;) {
            if (!atomic_load_explicit(&context->softwareCadenceRunning,
                                      memory_order_acquire))
                break;
            uint64_t now = mach_absolute_time();
            if (now >= nextDeadline) {
                if (now - nextDeadline > quantumTicks * 8)
                    nextDeadline = now;
                break;
            }
            uint64_t remainingTicks = nextDeadline - now;
            uint64_t remainingNanoseconds = (uint64_t)(
                (long double)remainingTicks * timebase.numer /
                timebase.denom);
            if (remainingNanoseconds == 0) break;
            struct timespec remaining = {
                .tv_sec = (time_t)(remainingNanoseconds / 1000000000ULL),
                .tv_nsec = (long)(remainingNanoseconds % 1000000000ULL),
            };
            (void)nanosleep(&remaining, NULL);
        }
    }
    MacWSDestroySoftwareAudioBuffers(buffers);
    return NULL;
}

static OSStatus MacWSAudioOutputUnitStart(AudioUnit unit) {
    MacWSEnsureAudioSymbols();
    MacWSAudioRenderContext *context = MacWSFindAudioContext(unit);
    if (!context || !MacWSNeedsSoftwareAudioCadence()) {
        return gMacWSOriginalAudioOutputUnitStart
            ? gMacWSOriginalAudioOutputUnitStart(unit) : kAudio_ParamError;
    }
    if (context->softwareCadenceThreadCreated) return noErr;
    atomic_store_explicit(&context->softwareCadenceRunning, true,
                          memory_order_release);
    int error = pthread_create(&context->softwareCadenceThread, NULL,
                               MacWSSoftwareAudioCadenceMain, context);
    if (error != 0) {
        atomic_store_explicit(&context->softwareCadenceRunning, false,
                              memory_order_release);
        fprintf(stderr,
                "#### MACWS-AUDIO software cadence start failed error=%d "
                "unit=%p\n", error, unit);
        return kAudio_ParamError;
    }
    context->softwareCadenceThreadCreated = true;
    fprintf(stderr,
            "#### MACWS-AUDIO software cadence started unit=%p rate=%.0f "
            "channels=%u\n", unit, context->format.mSampleRate,
            (unsigned)context->format.mChannelsPerFrame);
    return noErr;
}

static OSStatus MacWSAudioOutputUnitStop(AudioUnit unit) {
    MacWSEnsureAudioSymbols();
    MacWSAudioRenderContext *context = MacWSFindAudioContext(unit);
    if (!context || !MacWSNeedsSoftwareAudioCadence()) {
        return gMacWSOriginalAudioOutputUnitStop
            ? gMacWSOriginalAudioOutputUnitStop(unit) : kAudio_ParamError;
    }
    if (context->softwareCadenceThreadCreated) {
        atomic_store_explicit(&context->softwareCadenceRunning, false,
                              memory_order_release);
        pthread_join(context->softwareCadenceThread, NULL);
        context->softwareCadenceThreadCreated = false;
        fprintf(stderr,
                "#### MACWS-AUDIO software cadence stopped unit=%p\n", unit);
    }
    return noErr;
}

static OSStatus MacWSAudioComponentInstanceDispose(
    AudioComponentInstance instance) {
    MacWSEnsureAudioSymbols();
    MacWSAudioRenderContext *context = MacWSFindAudioContext(instance);
    if (context) {
        // Do not forward a second stop during ordinary M1 disposal.  Only the
        // M2 software backend owns a thread that must be joined here when a
        // client disposes without first calling AudioOutputUnitStop.
        if (context->softwareCadenceThreadCreated) {
            atomic_store_explicit(&context->softwareCadenceRunning, false,
                                  memory_order_release);
            pthread_join(context->softwareCadenceThread, NULL);
            context->softwareCadenceThreadCreated = false;
        }
        MacWSUnregisterAudioContext(context);
    }
    OSStatus status = gMacWSOriginalAudioComponentInstanceDispose
        ? gMacWSOriginalAudioComponentInstanceDispose(instance)
        : kAudio_ParamError;
    if (context) {
        if (context->ring) {
            munmap(context->ring, (size_t)MacWSAudioRingBytes(
                MACWS_AUDIO_RING_CAPACITY_FRAMES));
        }
        free(context);
    }
    return status;
}

static OSStatus MacWSAudioUnitSetProperty(
        AudioUnit unit, AudioUnitPropertyID property,
        AudioUnitScope scope, AudioUnitElement element,
        const void *data, UInt32 dataSize) {
    MacWSEnsureAudioSymbols();
    if (!gMacWSOriginalAudioUnitSetProperty) return kAudio_ParamError;
    if (property != kAudioUnitProperty_SetRenderCallback ||
        scope != kAudioUnitScope_Input || !data ||
        dataSize != sizeof(AURenderCallbackStruct)) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    const AURenderCallbackStruct *callback = data;
    if (!callback->inputProc) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    // Publish only the final output unit. Enabling the bridge for every
    // application must not also publish an effect/generator's intermediate
    // callback and race the real output stream for the shared ring.
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription description = {0};
    if (!component ||
        AudioComponentGetDescription(component, &description) != noErr ||
        description.componentType != kAudioUnitType_Output ||
        description.componentSubType == kAudioUnitSubType_GenericOutput) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    MacWSAudioRenderContext *context = calloc(1, sizeof(*context));
    if (!context) {
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    context->original = callback->inputProc;
    context->originalContext = callback->inputProcRefCon;
    context->unit = unit;
    context->producerToken = ((uint64_t)(uint32_t)getpid() << 32) |
        atomic_fetch_add_explicit(&gMacWSAudioProducerSerial, 1,
                                  memory_order_relaxed);
    UInt32 formatSize = sizeof(context->format);
    if (!gMacWSAudioUnitGetProperty ||
        gMacWSAudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, scope, element,
            &context->format, &formatSize) != noErr) {
        free(context);
        return gMacWSOriginalAudioUnitSetProperty(
            unit, property, scope, element, data, dataSize);
    }
    AURenderCallbackStruct wrapped = {
        .inputProc = MacWSAudioRenderCallback,
        .inputProcRefCon = context,
    };
    OSStatus status = gMacWSOriginalAudioUnitSetProperty(
        unit, property, scope, element, &wrapped, sizeof(wrapped));
    if (status != noErr) free(context);
    else MacWSRegisterAudioContext(context);
    return status;
}

void MacWSInstallAudioRenderBridge(void) {
    if (!MacWSAudioBridgeProcessEligible()) return;
    MacWSEnsureAudioSymbols();
}

DYLD_INTERPOSE(MacWSAudioUnitSetProperty, AudioUnitSetProperty)
DYLD_INTERPOSE(MacWSAudioOutputUnitStart, AudioOutputUnitStart)
DYLD_INTERPOSE(MacWSAudioOutputUnitStop, AudioOutputUnitStop)
DYLD_INTERPOSE(MacWSAudioComponentInstanceDispose,
               AudioComponentInstanceDispose)

__attribute__((constructor)) static void MacWSInitializeAudioRenderBridge(void) {
    // Audio output is a production capability, including applications
    // launched from Finder/Terminal rather than the curated launcher. The
    // native output daemon consumes this ring outside the chroot; the two
    // macOS audio catalog/HAL servers are not playback clients themselves.
    if (!MacWSAudioBridgeProcessEligible()) return;
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) == KERN_SUCCESS &&
        timebase.numer != 0) {
        long double ticks =
            (long double)MACWS_AUDIO_OWNER_SILENCE_NANOSECONDS *
            timebase.denom / timebase.numer;
        // The interval is fixed at 500 ms and mach timebase ratios are small;
        // its tick representation is therefore far below UINT64_MAX.
        gMacWSAudioOwnerSilenceTicks = (uint64_t)ticks;
    }
    if (gMacWSAudioOwnerSilenceTicks == 0)
        gMacWSAudioOwnerSilenceTicks =
            MACWS_AUDIO_OWNER_SILENCE_NANOSECONDS;
    MacWSInstallAudioRenderBridge();
}
