// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

/*
 * UHF X11 experimental GLX provider for hw/visionx.
 *
 * Copyright (C) 2026 I. Finder
 * http://www.lispm.net
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#ifdef HAVE_DIX_CONFIG_H
#include <dix-config.h>
#endif

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include <X11/X.h>
#include <X11/Xmd.h>
#include <X11/Xproto.h>

#include "CXOrgBridge/visionx_ddx.h"
#include "callback.h"
#include "dix.h"
#include "dixstruct.h"
#include "extnsionst.h"
#include "extension.h"
#include "globals.h"
#include "misc.h"
#include "os.h"
#include "../../os/osdep.h"
#include "pixmap.h"
#include "pixmapstr.h"
#include "scrnintstr.h"
#include "windowstr.h"

#define VISIONX_GLX_MAJOR_VERSION 1
#define VISIONX_GLX_MINOR_VERSION 3

#define X_GLsop_NewList 101
#define X_GLsop_EndList 102
#define X_GLsop_DeleteLists 103
#define X_GLsop_GenLists 104
#define X_GLsop_Finish 108
#define X_GLsop_GetError 115
#define X_GLsop_GetIntegerv 117
#define X_GLsop_GetString 129
#define X_GLsop_Flush 142

#define X_GLXRender 1
#define X_GLXRenderLarge 2
#define X_GLXCreateContext 3
#define X_GLXDestroyContext 4
#define X_GLXMakeCurrent 5
#define X_GLXIsDirect 6
#define X_GLXQueryVersion 7
#define X_GLXWaitGL 8
#define X_GLXWaitX 9
#define X_GLXSwapBuffers 11
#define X_GLXGetVisualConfigs 14
#define X_GLXQueryExtensionsString 18
#define X_GLXQueryServerString 19
#define X_GLXClientInfo 20
#define X_GLXGetFBConfigs 21
#define X_GLXCreateNewContext 24
#define X_GLXQueryContext 25
#define X_GLXMakeContextCurrent 26
#define X_GLXGetDrawableAttributes 29
#define X_GLXCreateWindow 31
#define X_GLXDestroyWindow 32

#define GLXBadRenderRequest 6
#define GLXBadLargeRequest 7

#define GLX_VENDOR 0x1
#define GLX_VERSION 0x2
#define GLX_EXTENSIONS 0x3

#define GLX_BUFFER_SIZE 2
#define GLX_LEVEL 3
#define GLX_RGBA 4
#define GLX_DOUBLEBUFFER 5
#define GLX_STEREO 6
#define GLX_AUX_BUFFERS 7
#define GLX_RED_SIZE 8
#define GLX_GREEN_SIZE 9
#define GLX_BLUE_SIZE 10
#define GLX_ALPHA_SIZE 11
#define GLX_DEPTH_SIZE 12
#define GLX_STENCIL_SIZE 13
#define GLX_ACCUM_RED_SIZE 14
#define GLX_ACCUM_GREEN_SIZE 15
#define GLX_ACCUM_BLUE_SIZE 16
#define GLX_ACCUM_ALPHA_SIZE 17
#define GLX_CONFIG_CAVEAT 0x20
#define GLX_DONT_CARE 0xffffffff
#define GLX_X_VISUAL_TYPE 0x22
#define GLX_TRANSPARENT_TYPE 0x23
#define GLX_TRANSPARENT_INDEX_VALUE 0x24
#define GLX_TRANSPARENT_RED_VALUE 0x25
#define GLX_TRANSPARENT_GREEN_VALUE 0x26
#define GLX_TRANSPARENT_BLUE_VALUE 0x27
#define GLX_TRANSPARENT_ALPHA_VALUE 0x28
#define GLX_NONE 0x8000
#define GLX_TRUE_COLOR 0x8002
#define GLX_SHARE_CONTEXT_EXT 0x800a
#define GLX_VISUAL_ID 0x800b
#define GLX_VISUAL_ID_EXT 0x800b
#define GLX_SCREEN 0x800c
#define GLX_SCREEN_EXT 0x800c
#define GLX_DRAWABLE_TYPE 0x8010
#define GLX_RENDER_TYPE 0x8011
#define GLX_X_RENDERABLE 0x8012
#define GLX_FBCONFIG_ID 0x8013
#define GLX_RGBA_TYPE 0x8014
#define GLX_WIDTH 0x801d
#define GLX_HEIGHT 0x801e
#define GLX_EVENT_MASK 0x801f
#define GLX_WINDOW_BIT 0x00000001
#define GLX_PIXMAP_BIT 0x00000002
#define GLX_RGBA_BIT 0x00000001
#define GLX_VISUAL_CAVEAT_EXT 0x20
#define GLX_SWAP_METHOD_OML 0x8060
#define GLX_BIND_TO_TEXTURE_RGB_EXT 0x20d0
#define GLX_BIND_TO_TEXTURE_RGBA_EXT 0x20d1
#define GLX_BIND_TO_MIPMAP_TEXTURE_EXT 0x20d2
#define GLX_BIND_TO_TEXTURE_TARGETS_EXT 0x20d3
#define GLX_Y_INVERTED_EXT 0x20d4
#define GLX_SAMPLE_BUFFERS_SGIS 100000
#define GLX_SAMPLES_SGIS 100001
#define GLX_VISUAL_SELECT_GROUP_SGIX 0x8028

#define X_TRUE_COLOR 4

#define GL_NO_ERROR 0
#define GL_VENDOR 0x1f00
#define GL_RENDERER 0x1f01
#define GL_VERSION 0x1f02
#define GL_EXTENSIONS 0x1f03
#define GL_AUX_BUFFERS 0x0c00
#define GL_MAX_LIGHTS 0x0d31
#define GL_MAX_CLIP_PLANES 0x0d32
#define GL_MAX_TEXTURE_SIZE 0x0d33
#define GL_MAX_MODELVIEW_STACK_DEPTH 0x0d36
#define GL_MAX_PROJECTION_STACK_DEPTH 0x0d38
#define GL_MAX_TEXTURE_STACK_DEPTH 0x0d39
#define GL_MAX_VIEWPORT_DIMS 0x0d3a
#define GL_SUBPIXEL_BITS 0x0d50
#define GL_RED_BITS 0x0d52
#define GL_GREEN_BITS 0x0d53
#define GL_BLUE_BITS 0x0d54
#define GL_ALPHA_BITS 0x0d55
#define GL_DEPTH_BITS 0x0d56
#define GL_STENCIL_BITS 0x0d57
#define GL_ACCUM_RED_BITS 0x0d58
#define GL_ACCUM_GREEN_BITS 0x0d59
#define GL_ACCUM_BLUE_BITS 0x0d5a
#define GL_ACCUM_ALPHA_BITS 0x0d5b
#define GL_MAX_TEXTURE_UNITS 0x84e2

#define VISIONX_GL_VENDOR_STRING "UHF X11"
#define VISIONX_GL_RENDERER_STRING "VisionGL Indirect (experimental)"
#define VISIONX_GL_VERSION_STRING "1.1 UHF X11 VisionGL"
#define VISIONX_GL_EXTENSIONS_STRING ""

#define VISIONX_GLX_VISUAL_PROPS 40
#define VISIONX_GLX_FBCONFIG_ID 1
#define VISIONX_GLX_FBCONFIG_ATTRIBS 44
#define VISIONX_GLX_FBCONFIG_WORDS (VISIONX_GLX_FBCONFIG_ATTRIBS * 2)
#define VISIONX_GLX_MAX_CONTEXTS 256
#define VISIONX_GLX_MAX_DRAWABLES 256
#define VISIONX_GLX_MAX_LARGE_RENDER_BYTES (16 * 1024 * 1024)
#define VISIONX_GLX_PRESENT_INTERVAL_USEC 8000ULL
#define VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS 16

typedef CARD32 GLXContextID;
typedef CARD32 GLXContextTag;
typedef CARD32 GLXDrawable;
typedef CARD32 GLXFBConfigID;
typedef CARD32 GLXWindow;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextTag contextTag;
} xVisionXGLXSingleReq;

typedef xVisionXGLXSingleReq xVisionXGLXRenderReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextTag contextTag;
    CARD16 requestNumber;
    CARD16 requestTotal;
    CARD32 dataBytes;
} xVisionXGLXRenderLargeReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 majorVersion;
    CARD32 minorVersion;
} xVisionXGLXQueryVersionReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextID context;
    CARD32 visual;
    CARD32 screen;
    GLXContextID shareList;
    BOOL isDirect;
    CARD8 reserved1;
    CARD16 reserved2;
} xVisionXGLXCreateContextReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextID context;
} xVisionXGLXDestroyContextReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXDrawable drawable;
    GLXContextID context;
    GLXContextTag oldContextTag;
} xVisionXGLXMakeCurrentReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextID context;
} xVisionXGLXIsDirectReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextTag contextTag;
    GLXDrawable drawable;
} xVisionXGLXSwapBuffersReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 screen;
} xVisionXGLXGetVisualConfigsReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 screen;
} xVisionXGLXQueryExtensionsStringReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 screen;
    CARD32 name;
} xVisionXGLXQueryServerStringReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 major;
    CARD32 minor;
    CARD32 numbytes;
} xVisionXGLXClientInfoReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 screen;
} xVisionXGLXGetFBConfigsReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextID context;
    GLXFBConfigID fbconfig;
    CARD32 screen;
    CARD32 renderType;
    GLXContextID shareList;
    BOOL isDirect;
    CARD8 reserved1;
    CARD16 reserved2;
} xVisionXGLXCreateNewContextReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextID context;
} xVisionXGLXQueryContextReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXContextTag oldContextTag;
    GLXDrawable drawable;
    GLXDrawable readDrawable;
    GLXContextID context;
} xVisionXGLXMakeContextCurrentReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXDrawable drawable;
} xVisionXGLXGetDrawableAttributesReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    CARD32 screen;
    GLXFBConfigID fbconfig;
    CARD32 window;
    GLXWindow glxWindow;
    CARD32 numAttribs;
} xVisionXGLXCreateWindowReq;

typedef struct {
    CARD8 reqType;
    CARD8 glxCode;
    CARD16 length;
    GLXWindow glxWindow;
} xVisionXGLXDestroyWindowReq;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 majorVersion;
    CARD32 minorVersion;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXQueryVersionReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    GLXContextTag contextTag;
    CARD32 pad2;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXMakeCurrentReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    BOOL isDirect;
    CARD8 pad1;
    CARD16 pad2;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
    CARD32 pad7;
} xVisionXGLXIsDirectReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 numVisuals;
    CARD32 numProps;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXGetVisualConfigsReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 numFBConfigs;
    CARD32 numAttribs;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXGetFBConfigsReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 n;
    CARD32 pad2;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXQueryContextReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 numAttribs;
    CARD32 pad2;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXGetDrawableAttributesReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 pad1;
    CARD32 n;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXStringReply;

typedef struct {
    BYTE type;
    CARD8 unused;
    CARD16 sequenceNumber;
    CARD32 length;
    CARD32 retval;
    CARD32 size;
    CARD32 pad3;
    CARD32 pad4;
    CARD32 pad5;
    CARD32 pad6;
} xVisionXGLXSingleReply;

typedef struct {
    GLXContextID id;
    ClientPtr owner;
    CARD32 visual;
    CARD32 screen;
    GLXFBConfigID fbconfig;
    GLXContextID shareList;
    CARD32 renderType;
    GLXDrawable currentDrawable;
    uint8_t *largeRenderBuffer;
    size_t largeRenderLength;
    size_t largeRenderCapacity;
    CARD16 largeRenderRequestsSoFar;
    CARD16 largeRenderRequestsTotal;
    Bool inUse;
} VisionXGLXContextRecord;

typedef struct {
    GLXDrawable id;
    ClientPtr owner;
    GLXDrawable backing;
    CARD32 visual;
    CARD32 width;
    CARD32 height;
    uint64_t pendingSwapSerial;
    uint64_t pendingSwapSerials[VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS];
    unsigned int pendingSwapCount;
    uint64_t completedSwapSerial;
    OsTimerPtr framePaceTimer;
    CARD64 lastClientPaceUsec;
    CARD64 lastPresentationFrameUsec;
    Bool captureFrameCommands;
    Bool presentFrameOnSwap;
    Bool capturedFrameRenderCommands;
    Bool suppressedFrameCapture;
    Bool inUse;
} VisionXGLXDrawableRecord;

typedef struct VisionXGLXSwapCompletionRec {
    GLXDrawable drawable;
    uint64_t swapSerial;
    struct VisionXGLXSwapCompletionRec *next;
} VisionXGLXSwapCompletionRec;

static ExtensionEntry *visionxGLXExtension;
static Bool visionxGLXClientCallbackRegistered;
static VisionXGLXContextRecord visionxGLXContexts[VISIONX_GLX_MAX_CONTEXTS];
static VisionXGLXDrawableRecord visionxGLXDrawables[VISIONX_GLX_MAX_DRAWABLES];
static uint64_t visionxGLXNextSwapSerial = 1;
static int visionxGLXSwapWakePipe[2] = { -1, -1 };
static pthread_mutex_t visionxGLXSwapCompletionLock = PTHREAD_MUTEX_INITIALIZER;
static VisionXGLXSwapCompletionRec *visionxGLXSwapCompletionHead;
static VisionXGLXSwapCompletionRec *visionxGLXSwapCompletionTail;

static void visionxGLXSignalSwapWaiters(VisionXGLXDrawableRecord *drawable);
static unsigned int visionxGLXFramePaceIntervalUsec(void);
static VisionXGLXDrawableRecord *visionxGLXDrawable(GLXDrawable drawable);
void visionx_glx_refresh_window_presentation(WindowPtr presentation);
void VisionXGLXRegisterExtension(void);
void VisionXGLXExtensionInit(void);

static void visionxGLXRuntimeLog(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void
visionxGLXRuntimeLog(const char *format, ...)
{
    char message[256];
    va_list args;

    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    message[sizeof(message) - 1] = '\0';
    visionx_ddx_log_message(message);
}

void
VisionXGLXRegisterExtension(void)
{
    static Bool registered = FALSE;
    static const ExtensionModule visionxGLXExtensions[] = {
        {VisionXGLXExtensionInit, "GLX", NULL},
    };

    if (registered)
        return;
    registered = TRUE;
    LoadExtensionList(visionxGLXExtensions, 1, FALSE);
}

static Bool
visionxGLXEnabled(void)
{
    const char *flag = getenv("VISIONX_EXPERIMENTAL_GLX");
    return flag != NULL && strcmp(flag, "1") == 0;
}

static int
visionxGLXError(int error)
{
    return visionxGLXExtension != NULL ? visionxGLXExtension->errorBase + error : BadImplementation;
}

static Bool
visionxGLXSwapWakeClient(ClientPtr client, void *closure)
{
    (void) closure;
    if (client != NULL)
        ClientWakeup(client);
    return TRUE;
}

static Bool
visionxGLXShouldPresentSwap(ClientPtr client, VisionXGLXDrawableRecord *drawable, uint64_t swapSerial)
{
    (void) client;
    (void) drawable;
    (void) swapSerial;
    return TRUE;
}

static Bool
visionxGLXBackpressureEnabled(void)
{
    static Bool initialized;
    static Bool enabled;
    const char *value;

    if (initialized)
        return enabled;
    initialized = TRUE;

    value = getenv("VISIONX_GLX_BACKPRESSURE");
    enabled = value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
    visionxGLXRuntimeLog("GLX backpressure enabled=%u", (unsigned) enabled);
    return enabled;
}

static unsigned int
visionxGLXMaxPendingSwaps(void)
{
    static Bool initialized;
    static unsigned int maxPendingSwaps;
    const char *value;
    long parsed;

    if (initialized)
        return maxPendingSwaps;
    initialized = TRUE;

    value = getenv("VISIONX_GLX_MAX_PENDING_SWAPS");
    if (value == NULL || value[0] == '\0')
        value = "1";

    parsed = strtol(value, NULL, 10);
    if (parsed < 1)
        parsed = 1;
    if (parsed > VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS)
        parsed = VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS;
    maxPendingSwaps = (unsigned int) parsed;
    visionxGLXRuntimeLog("GLX max pending swaps=%u", maxPendingSwaps);
    return maxPendingSwaps;
}

static Bool
visionxGLXDrawableAtPendingLimit(VisionXGLXDrawableRecord *drawable)
{
    return drawable != NULL &&
           drawable->pendingSwapCount >= visionxGLXMaxPendingSwaps();
}

static Bool
visionxGLXSleepClientForPendingSwap(ClientPtr client, VisionXGLXDrawableRecord *drawable, Bool replayCurrentRequest)
{
    static uint64_t sleepLogCount;

    if (!visionxGLXBackpressureEnabled() ||
        client == NULL ||
        drawable == NULL ||
        !visionxGLXDrawableAtPendingLimit(drawable))
        return FALSE;

    if (!ClientSleep(client, visionxGLXSwapWakeClient, drawable))
        return FALSE;

    if (replayCurrentRequest) {
        ResetCurrentRequest(client);
        client->sequence--;
    }

    sleepLogCount++;
    if (sleepLogCount <= 12 || (sleepLogCount % 240) == 0) {
        visionxGLXRuntimeLog("GLX client slept drawable=%u pendingSerial=%llu pendingCount=%u replay=%u count=%llu",
                    (unsigned) drawable->id,
                    (unsigned long long) drawable->pendingSwapSerial,
                    drawable->pendingSwapCount,
                    (unsigned) replayCurrentRequest,
                    (unsigned long long) sleepLogCount);
    }
    return TRUE;
}

static void
visionxGLXTrackPendingSwap(VisionXGLXDrawableRecord *drawable, uint64_t swapSerial)
{
    if (drawable == NULL || swapSerial == 0)
        return;

    if (drawable->pendingSwapCount < VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS) {
        drawable->pendingSwapSerials[drawable->pendingSwapCount++] = swapSerial;
    } else {
        memmove(drawable->pendingSwapSerials,
                drawable->pendingSwapSerials + 1,
                sizeof(drawable->pendingSwapSerials[0]) * (VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS - 1));
        drawable->pendingSwapSerials[VISIONX_GLX_MAX_PENDING_TRACKED_SWAPS - 1] = swapSerial;
    }
    drawable->pendingSwapSerial = swapSerial;
}

static Bool
visionxGLXRemovePendingSwap(VisionXGLXDrawableRecord *drawable, uint64_t swapSerial)
{
    if (drawable == NULL || swapSerial == 0)
        return FALSE;

    for (unsigned int i = 0; i < drawable->pendingSwapCount; i++) {
        if (drawable->pendingSwapSerials[i] != swapSerial)
            continue;

        if (i + 1 < drawable->pendingSwapCount) {
            memmove(drawable->pendingSwapSerials + i,
                    drawable->pendingSwapSerials + i + 1,
                    sizeof(drawable->pendingSwapSerials[0]) * (drawable->pendingSwapCount - i - 1));
        }
        drawable->pendingSwapCount--;
        drawable->pendingSwapSerial = drawable->pendingSwapCount > 0
            ? drawable->pendingSwapSerials[drawable->pendingSwapCount - 1]
            : 0;
        return TRUE;
    }

    return FALSE;
}

static void
visionxGLXClearPendingSwaps(VisionXGLXDrawableRecord *drawable)
{
    if (drawable == NULL)
        return;
    drawable->pendingSwapSerial = 0;
    drawable->pendingSwapCount = 0;
    memset(drawable->pendingSwapSerials, 0, sizeof(drawable->pendingSwapSerials));
}

static void
visionxGLXCancelFramePaceTimer(VisionXGLXDrawableRecord *drawable)
{
    if (drawable == NULL || drawable->framePaceTimer == NULL)
        return;

    TimerFree(drawable->framePaceTimer);
    drawable->framePaceTimer = NULL;
}

static Bool
visionxGLXDrawableReadyForFrame(VisionXGLXDrawableRecord *drawable, CARD64 now)
{
    if (drawable == NULL || drawable->lastPresentationFrameUsec == 0)
        return TRUE;
    return now - drawable->lastPresentationFrameUsec >= VISIONX_GLX_PRESENT_INTERVAL_USEC;
}

static Bool
visionxGLXShouldCaptureRender(ClientPtr client, VisionXGLXContextRecord *context)
{
    VisionXGLXDrawableRecord *drawable;

    (void) client;
    if (context == NULL)
        return TRUE;

    drawable = visionxGLXDrawable(context->currentDrawable);
    if (drawable == NULL)
        return TRUE;

    return drawable->captureFrameCommands;
}

static void
visionxGLXInitializeDrawableSampling(VisionXGLXDrawableRecord *drawable)
{
    if (drawable == NULL)
        return;
    drawable->lastPresentationFrameUsec = 0;
    drawable->lastClientPaceUsec = 0;
    drawable->captureFrameCommands = TRUE;
    drawable->presentFrameOnSwap = TRUE;
    drawable->capturedFrameRenderCommands = FALSE;
}

static void
visionxGLXResetDrawableSampling(VisionXGLXDrawableRecord *drawable)
{
    if (drawable == NULL)
        return;
    drawable->lastPresentationFrameUsec = 0;
    drawable->lastClientPaceUsec = 0;
    drawable->captureFrameCommands = FALSE;
    drawable->presentFrameOnSwap = FALSE;
    drawable->capturedFrameRenderCommands = FALSE;
}

static Bool
visionxGLXShouldPresentFrame(ClientPtr client, VisionXGLXDrawableRecord *drawable, uint64_t swapSerial)
{
    if (drawable == NULL)
        return visionxGLXShouldPresentSwap(client, drawable, swapSerial);

    return drawable->presentFrameOnSwap &&
           drawable->capturedFrameRenderCommands &&
           visionxGLXShouldPresentSwap(client, drawable, swapSerial);
}

static void
visionxGLXDidSwapFrame(VisionXGLXDrawableRecord *drawable, Bool presentedCurrentFrame)
{
    CARD64 now;
    static uint64_t samplingLogCount;

    if (drawable == NULL)
        return;

    now = GetTimeInMicros();
    if (presentedCurrentFrame)
        drawable->lastPresentationFrameUsec = now;

    drawable->capturedFrameRenderCommands = FALSE;
    if (visionxGLXBackpressureEnabled()) {
        drawable->captureFrameCommands = TRUE;
        drawable->presentFrameOnSwap = TRUE;
    } else if (visionxGLXDrawableReadyForFrame(drawable, now)) {
        drawable->captureFrameCommands = TRUE;
        drawable->presentFrameOnSwap = TRUE;
    } else {
        drawable->captureFrameCommands = FALSE;
        drawable->presentFrameOnSwap = FALSE;
    }

    samplingLogCount++;
    if (samplingLogCount <= 12 || (samplingLogCount % 240) == 0) {
        visionxGLXRuntimeLog("GLX sampling drawable=%u presented=%u nextCapture=%u nextPresent=%u count=%llu",
                    (unsigned) drawable->id,
                    (unsigned) presentedCurrentFrame,
                    (unsigned) drawable->captureFrameCommands,
                    (unsigned) drawable->presentFrameOnSwap,
                    (unsigned long long) samplingLogCount);
    }
}

static void
visionxGLXNoteCapturedRender(VisionXGLXContextRecord *context, Bool captureDrawCalls)
{
    VisionXGLXDrawableRecord *drawable;

    if (context == NULL || !captureDrawCalls)
        return;

    drawable = visionxGLXDrawable(context->currentDrawable);
    if (drawable != NULL)
        drawable->capturedFrameRenderCommands = TRUE;
}

static void
visionxGLXArmDrawableForFrame(VisionXGLXDrawableRecord *drawable)
{
    if (drawable == NULL)
        return;

    drawable->captureFrameCommands = TRUE;
    drawable->presentFrameOnSwap = TRUE;
    drawable->capturedFrameRenderCommands = FALSE;
}

static void
visionxGLXArmDrawableForFrameIfReady(VisionXGLXDrawableRecord *drawable)
{
    CARD64 now;

    if (drawable == NULL)
        return;

    now = GetTimeInMicros();
    if (visionxGLXBackpressureEnabled() ||
        visionxGLXDrawableReadyForFrame(drawable, now)) {
        visionxGLXArmDrawableForFrame(drawable);
    }
}

static Bool
visionxGLXShouldDropRender(ClientPtr client, VisionXGLXContextRecord *context)
{
    (void) client;
    (void) context;
    return FALSE;
}

static unsigned int
visionxGLXFramePaceIntervalUsec(void)
{
    static Bool initialized;
    static unsigned int intervalUsec;
    const char *value;
    long parsed;

    if (initialized)
        return intervalUsec;
    initialized = TRUE;

    value = getenv("VISIONX_GLX_CLIENT_PACE_US");
    if (value == NULL || value[0] == '\0')
        value = "0";

    parsed = strtol(value, NULL, 10);
    if (parsed < 0)
        parsed = 0;
    if (parsed > 50000)
        parsed = 50000;
    intervalUsec = (unsigned int) parsed;
    visionxGLXRuntimeLog("GLX client pace interval usec=%u", intervalUsec);
    return intervalUsec;
}

static CARD32
visionxGLXFramePaceTimerNotify(OsTimerPtr timer, CARD32 time, void *arg)
{
    VisionXGLXDrawableRecord *drawable = arg;

    (void) timer;
    (void) time;

    if (drawable != NULL && drawable->inUse) {
        visionxGLXArmDrawableForFrameIfReady(drawable);
        visionxGLXSignalSwapWaiters(drawable);
    }
    return 0;
}

static Bool
visionxGLXMaybeSleepClientForFramePace(ClientPtr client, VisionXGLXDrawableRecord *drawable, Bool replayCurrentRequest)
{
    CARD64 now;
    CARD64 base;
    CARD64 target;
    CARD64 remaining;
    unsigned int intervalUsec;
    CARD32 millis;
    static uint64_t paceSleepLogCount;

    if (visionxGLXBackpressureEnabled() ||
        client == NULL ||
        drawable == NULL ||
        drawable->lastPresentationFrameUsec == 0)
        return FALSE;

    intervalUsec = visionxGLXFramePaceIntervalUsec();
    if (intervalUsec == 0)
        return FALSE;

    now = GetTimeInMicros();
    base = drawable->lastClientPaceUsec != 0 ? drawable->lastClientPaceUsec : now;
    target = base + intervalUsec;
    if (target <= now) {
        drawable->lastClientPaceUsec = now;
        visionxGLXArmDrawableForFrameIfReady(drawable);
        return FALSE;
    }

    remaining = target - now;
    millis = (CARD32) ((remaining + 999) / 1000);
    if (millis == 0)
        millis = 1;

    if (!ClientSleep(client, visionxGLXSwapWakeClient, drawable))
        return FALSE;

    drawable->lastClientPaceUsec = target;
    if (replayCurrentRequest) {
        ResetCurrentRequest(client);
        client->sequence--;
    }
    drawable->framePaceTimer = TimerSet(drawable->framePaceTimer,
                                        0,
                                        millis,
                                        visionxGLXFramePaceTimerNotify,
                                        drawable);
    if (drawable->framePaceTimer == NULL) {
        visionxGLXArmDrawableForFrame(drawable);
        ClientSignalAll(CLIENT_SIGNAL_ANY, visionxGLXSwapWakeClient, drawable);
        return TRUE;
    }

    paceSleepLogCount++;
    if (paceSleepLogCount <= 12 || (paceSleepLogCount % 240) == 0) {
        visionxGLXRuntimeLog("GLX client frame paced drawable=%u waitMS=%u replay=%u count=%llu",
                    (unsigned) drawable->id,
                    (unsigned) millis,
                    (unsigned) replayCurrentRequest,
                    (unsigned long long) paceSleepLogCount);
    }
    return TRUE;
}

static unsigned int
visionxGLXSkippedSwapPaceUsec(void)
{
    static Bool initialized;
    static unsigned int paceUsec;
    const char *value;
    long parsed;

    if (initialized)
        return paceUsec;
    initialized = TRUE;

    value = getenv("VISIONX_GLX_SKIP_PACE_US");
    if (value == NULL || value[0] == '\0')
        value = "0";

    parsed = strtol(value, NULL, 10);
    if (parsed < 0)
        parsed = 0;
    if (parsed > 5000)
        parsed = 5000;
    paceUsec = (unsigned int) parsed;
    visionxGLXRuntimeLog("GLX skipped swap pace usec=%u", paceUsec);
    return paceUsec;
}

static void
visionxGLXPaceSkippedSwap(void)
{
    unsigned int paceUsec = visionxGLXSkippedSwapPaceUsec();

    if (paceUsec > 0)
        usleep((useconds_t) paceUsec);
}

static int
visionxGLXDiscardBufferedFrameRequests(ClientPtr client)
{
    static const CARD8 frameRequestMinors[] = {
        X_GLXRender,
        X_GLXRenderLarge,
        X_GLXSwapBuffers,
    };

    if (visionxGLXExtension == NULL)
        return 0;

    return VisionXDiscardBufferedClientRequests(client,
                                                (CARD8) visionxGLXExtension->base,
                                                frameRequestMinors,
                                                (int) (sizeof(frameRequestMinors) / sizeof(frameRequestMinors[0])),
                                                4096);
}

static Bool
visionxGLXDiscardSkippedFramesEnabled(void)
{
    static Bool initialized;
    static Bool enabled;
    const char *value;

    if (initialized)
        return enabled;
    initialized = TRUE;

    value = getenv("VISIONX_GLX_DISCARD_SKIPPED_FRAMES");
    enabled = value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
    visionxGLXRuntimeLog("GLX discard skipped frames enabled=%u", (unsigned) enabled);
    return enabled;
}

static uint64_t
visionxGLXAllocateSwapSerial(void)
{
    uint64_t serial = visionxGLXNextSwapSerial++;

    if (visionxGLXNextSwapSerial == 0)
        visionxGLXNextSwapSerial = 1;
    if (serial == 0)
        serial = visionxGLXNextSwapSerial++;
    return serial;
}

static void
visionxGLXSignalSwapWaiters(VisionXGLXDrawableRecord *drawable)
{
    int count;
    static uint64_t wakeLogCount;

    if (drawable == NULL)
        return;

    count = ClientSignalAll(CLIENT_SIGNAL_ANY, visionxGLXSwapWakeClient, drawable);
    if (count > 0) {
        wakeLogCount++;
        if (wakeLogCount <= 12 || (wakeLogCount % 2400) == 0) {
            ErrorF("VisionX GLX: woke %d client(s) drawable=%u completedSerial=%llu count=%llu\n",
                   count,
                   (unsigned) drawable->id,
                   (unsigned long long) drawable->completedSwapSerial,
                   (unsigned long long) wakeLogCount);
            visionxGLXRuntimeLog("GLX woke %d client(s) drawable=%u completedSerial=%llu count=%llu",
                        count,
                        (unsigned) drawable->id,
                        (unsigned long long) drawable->completedSwapSerial,
                        (unsigned long long) wakeLogCount);
        }
    }
}

static void
visionxGLXCompleteSwap(GLXDrawable drawable, uint64_t swapSerial)
{
    VisionXGLXDrawableRecord *record = visionxGLXDrawable(drawable);
    static uint64_t completionLogCount;

    if (record == NULL || !record->inUse) {
        ErrorF("VisionX GLX: ignored swap completion for unknown drawable=%u serial=%llu\n",
               (unsigned) drawable,
               (unsigned long long) swapSerial);
        return;
    }

    if (!visionxGLXRemovePendingSwap(record, swapSerial)) {
        if (swapSerial > record->completedSwapSerial)
            record->completedSwapSerial = swapSerial;
        return;
    }

    if (swapSerial > record->completedSwapSerial)
        record->completedSwapSerial = swapSerial;
    completionLogCount++;
    if (completionLogCount <= 12 || (completionLogCount % 240) == 0) {
        visionxGLXRuntimeLog("GLX swap completed drawable=%u serial=%llu pendingCount=%u count=%llu",
                    (unsigned) drawable,
                    (unsigned long long) swapSerial,
                    record->pendingSwapCount,
                    (unsigned long long) completionLogCount);
    }
    visionxGLXSignalSwapWaiters(record);
}

static VisionXGLXSwapCompletionRec *
visionxGLXPopSwapCompletions(void)
{
    VisionXGLXSwapCompletionRec *head;

    pthread_mutex_lock(&visionxGLXSwapCompletionLock);
    head = visionxGLXSwapCompletionHead;
    visionxGLXSwapCompletionHead = NULL;
    visionxGLXSwapCompletionTail = NULL;
    pthread_mutex_unlock(&visionxGLXSwapCompletionLock);

    return head;
}

static void
visionxGLXDrainSwapWakePipe(int fd, int ready, void *data)
{
    char buffer[128];
    VisionXGLXSwapCompletionRec *completion;
    ssize_t result = 0;

    (void) data;

    if ((ready & X_NOTIFY_READ) != 0) {
        do {
            result = read(fd, buffer, sizeof(buffer));
        } while (result > 0);
        if (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            ErrorF("VisionX GLX: swap wake pipe read failed errno=%d\n", errno);
        }
    }

    completion = visionxGLXPopSwapCompletions();
    while (completion != NULL) {
        VisionXGLXSwapCompletionRec *next = completion->next;
        visionxGLXCompleteSwap(completion->drawable, completion->swapSerial);
        free(completion);
        completion = next;
    }
}

static Bool
visionxGLXOpenSwapWakePipe(void)
{
    if (visionxGLXSwapWakePipe[0] >= 0)
        return TRUE;

    if (pipe(visionxGLXSwapWakePipe) != 0) {
        ErrorF("VisionX GLX: swap wake pipe failed errno=%d\n", errno);
        visionxGLXSwapWakePipe[0] = -1;
        visionxGLXSwapWakePipe[1] = -1;
        return FALSE;
    }

    fcntl(visionxGLXSwapWakePipe[0], F_SETFL, O_NONBLOCK);
    fcntl(visionxGLXSwapWakePipe[1], F_SETFL, O_NONBLOCK);
    if (!SetNotifyFd(visionxGLXSwapWakePipe[0], visionxGLXDrainSwapWakePipe, X_NOTIFY_READ, NULL)) {
        ErrorF("VisionX GLX: swap wake pipe notify registration failed\n");
        close(visionxGLXSwapWakePipe[0]);
        close(visionxGLXSwapWakePipe[1]);
        visionxGLXSwapWakePipe[0] = -1;
        visionxGLXSwapWakePipe[1] = -1;
        return FALSE;
    }

    ErrorF("VisionX GLX: swap wake pipe registered readFd=%d writeFd=%d\n",
           visionxGLXSwapWakePipe[0],
           visionxGLXSwapWakePipe[1]);
    return TRUE;
}

static void
visionxGLXCloseSwapWakePipe(void)
{
    VisionXGLXSwapCompletionRec *completion;

    if (visionxGLXSwapWakePipe[0] >= 0) {
        RemoveNotifyFd(visionxGLXSwapWakePipe[0]);
        close(visionxGLXSwapWakePipe[0]);
        visionxGLXSwapWakePipe[0] = -1;
    }
    if (visionxGLXSwapWakePipe[1] >= 0) {
        close(visionxGLXSwapWakePipe[1]);
        visionxGLXSwapWakePipe[1] = -1;
    }

    completion = visionxGLXPopSwapCompletions();
    while (completion != NULL) {
        VisionXGLXSwapCompletionRec *next = completion->next;
        free(completion);
        completion = next;
    }
}

void
visionx_ddx_glx_swap_presented(visionx_xid_t drawable, uint64_t swap_serial)
{
    VisionXGLXSwapCompletionRec *completion = calloc(1, sizeof(*completion));
    const char byte = 0;

    if (completion == NULL) {
        ErrorF("VisionX GLX: failed to allocate swap completion drawable=%u serial=%llu\n",
               (unsigned) drawable,
               (unsigned long long) swap_serial);
        return;
    }

    completion->drawable = drawable;
    completion->swapSerial = swap_serial;

    pthread_mutex_lock(&visionxGLXSwapCompletionLock);
    if (visionxGLXSwapCompletionTail != NULL)
        visionxGLXSwapCompletionTail->next = completion;
    else
        visionxGLXSwapCompletionHead = completion;
    visionxGLXSwapCompletionTail = completion;
    pthread_mutex_unlock(&visionxGLXSwapCompletionLock);

    if (visionxGLXSwapWakePipe[1] >= 0) {
        ssize_t result = write(visionxGLXSwapWakePipe[1], &byte, 1);
        (void) result;
    }
}

static CARD32
visionxGLXVisualID(CARD32 screen)
{
    if (screen >= (CARD32) screenInfo.numScreens || screenInfo.screens[screen] == NULL)
        return 0;
    return screenInfo.screens[screen]->rootVisual;
}

static VisionXGLXContextRecord *
visionxGLXContext(GLXContextID context)
{
    for (size_t i = 0; i < VISIONX_GLX_MAX_CONTEXTS; i++) {
        if (visionxGLXContexts[i].inUse && visionxGLXContexts[i].id == context)
            return &visionxGLXContexts[i];
    }
    return NULL;
}

static void
visionxGLXResetLargeRender(VisionXGLXContextRecord *context)
{
    if (context == NULL)
        return;

    free(context->largeRenderBuffer);
    context->largeRenderBuffer = NULL;
    context->largeRenderLength = 0;
    context->largeRenderCapacity = 0;
    context->largeRenderRequestsSoFar = 0;
    context->largeRenderRequestsTotal = 0;
}

static Bool
visionxGLXAppendLargeRenderBytes(VisionXGLXContextRecord *context, const uint8_t *bytes, size_t length)
{
    uint8_t *nextBuffer;
    size_t requiredLength;
    size_t nextCapacity;

    if (context == NULL || (length > 0 && bytes == NULL))
        return FALSE;
    if (length > VISIONX_GLX_MAX_LARGE_RENDER_BYTES ||
        context->largeRenderLength > VISIONX_GLX_MAX_LARGE_RENDER_BYTES - length)
        return FALSE;

    requiredLength = context->largeRenderLength + length;
    if (requiredLength > context->largeRenderCapacity) {
        nextCapacity = context->largeRenderCapacity == 0 ? 4096 : context->largeRenderCapacity;
        while (nextCapacity < requiredLength) {
            if (nextCapacity > VISIONX_GLX_MAX_LARGE_RENDER_BYTES / 2) {
                nextCapacity = VISIONX_GLX_MAX_LARGE_RENDER_BYTES;
                break;
            }
            nextCapacity *= 2;
        }
        nextBuffer = realloc(context->largeRenderBuffer, nextCapacity);
        if (nextBuffer == NULL)
            return FALSE;
        context->largeRenderBuffer = nextBuffer;
        context->largeRenderCapacity = nextCapacity;
    }

    if (length > 0)
        memcpy(context->largeRenderBuffer + context->largeRenderLength, bytes, length);
    context->largeRenderLength = requiredLength;
    return TRUE;
}

static void
visionxGLXRememberContext(ClientPtr client, GLXContextID context, CARD32 screen, CARD32 visual, GLXFBConfigID fbconfig, GLXContextID shareList, CARD32 renderType)
{
    VisionXGLXContextRecord *existing = visionxGLXContext(context);
    if (existing != NULL) {
        existing->owner = client;
        existing->screen = screen;
        existing->visual = visual;
        existing->fbconfig = fbconfig;
        existing->shareList = shareList;
        existing->renderType = renderType;
        return;
    }

    for (size_t i = 0; i < VISIONX_GLX_MAX_CONTEXTS; i++) {
        if (!visionxGLXContexts[i].inUse) {
            visionxGLXContexts[i].inUse = TRUE;
            visionxGLXContexts[i].id = context;
            visionxGLXContexts[i].owner = client;
            visionxGLXContexts[i].screen = screen;
            visionxGLXContexts[i].visual = visual;
            visionxGLXContexts[i].fbconfig = fbconfig;
            visionxGLXContexts[i].shareList = shareList;
            visionxGLXContexts[i].renderType = renderType;
            return;
        }
    }
}

static void
visionxGLXForgetContext(GLXContextID context)
{
    VisionXGLXContextRecord *record = visionxGLXContext(context);
    if (record != NULL) {
        visionxGLXResetLargeRender(record);
        memset(record, 0, sizeof(*record));
    }
}

static VisionXGLXDrawableRecord *
visionxGLXDrawable(GLXDrawable drawable)
{
    for (size_t i = 0; i < VISIONX_GLX_MAX_DRAWABLES; i++) {
        if (visionxGLXDrawables[i].inUse && visionxGLXDrawables[i].id == drawable)
            return &visionxGLXDrawables[i];
    }
    return NULL;
}

static void
visionxGLXRememberDrawable(ClientPtr client, GLXDrawable drawable, GLXDrawable backing, CARD32 visual, CARD32 width, CARD32 height)
{
    VisionXGLXDrawableRecord *existing = visionxGLXDrawable(drawable);
    if (existing != NULL) {
        existing->owner = client;
        existing->backing = backing;
        existing->visual = visual;
        existing->width = width;
        existing->height = height;
        return;
    }

    for (size_t i = 0; i < VISIONX_GLX_MAX_DRAWABLES; i++) {
        if (!visionxGLXDrawables[i].inUse) {
            visionxGLXDrawables[i].inUse = TRUE;
            visionxGLXDrawables[i].id = drawable;
            visionxGLXDrawables[i].owner = client;
            visionxGLXDrawables[i].backing = backing;
            visionxGLXDrawables[i].visual = visual;
            visionxGLXDrawables[i].width = width;
            visionxGLXDrawables[i].height = height;
            visionxGLXInitializeDrawableSampling(&visionxGLXDrawables[i]);
            return;
        }
    }
}

static void
visionxGLXForgetDrawable(GLXDrawable drawable)
{
    VisionXGLXDrawableRecord *record = visionxGLXDrawable(drawable);
    if (record != NULL) {
        visionxGLXCancelFramePaceTimer(record);
        visionxGLXResetDrawableSampling(record);
        visionxGLXClearPendingSwaps(record);
        visionxGLXSignalSwapWaiters(record);
        memset(record, 0, sizeof(*record));
    }
}

static void
visionxGLXCleanupClient(ClientPtr client)
{
    for (size_t i = 0; i < VISIONX_GLX_MAX_CONTEXTS; i++) {
        if (visionxGLXContexts[i].inUse && visionxGLXContexts[i].owner == client) {
            visionx_ddx_glx_destroy_context(visionx_ddx_current_screen(), visionxGLXContexts[i].id);
            visionxGLXResetLargeRender(&visionxGLXContexts[i]);
            memset(&visionxGLXContexts[i], 0, sizeof(visionxGLXContexts[i]));
        }
    }

    for (size_t i = 0; i < VISIONX_GLX_MAX_DRAWABLES; i++) {
        if (visionxGLXDrawables[i].inUse && visionxGLXDrawables[i].owner == client) {
            visionx_ddx_glx_destroy_drawable(visionx_ddx_current_screen(), visionxGLXDrawables[i].id);
            visionxGLXCancelFramePaceTimer(&visionxGLXDrawables[i]);
            visionxGLXResetDrawableSampling(&visionxGLXDrawables[i]);
            visionxGLXClearPendingSwaps(&visionxGLXDrawables[i]);
            visionxGLXSignalSwapWaiters(&visionxGLXDrawables[i]);
            memset(&visionxGLXDrawables[i], 0, sizeof(visionxGLXDrawables[i]));
        }
    }
}

static void
visionxGLXCleanupAll(void)
{
    for (size_t i = 0; i < VISIONX_GLX_MAX_CONTEXTS; i++) {
        if (visionxGLXContexts[i].inUse) {
            visionx_ddx_glx_destroy_context(visionx_ddx_current_screen(), visionxGLXContexts[i].id);
            visionxGLXResetLargeRender(&visionxGLXContexts[i]);
        }
    }

    for (size_t i = 0; i < VISIONX_GLX_MAX_DRAWABLES; i++) {
        if (visionxGLXDrawables[i].inUse) {
            visionx_ddx_glx_destroy_drawable(visionx_ddx_current_screen(), visionxGLXDrawables[i].id);
            visionxGLXCancelFramePaceTimer(&visionxGLXDrawables[i]);
            visionxGLXResetDrawableSampling(&visionxGLXDrawables[i]);
            visionxGLXClearPendingSwaps(&visionxGLXDrawables[i]);
            visionxGLXSignalSwapWaiters(&visionxGLXDrawables[i]);
        }
    }

    memset(visionxGLXContexts, 0, sizeof(visionxGLXContexts));
    memset(visionxGLXDrawables, 0, sizeof(visionxGLXDrawables));
    visionxGLXNextSwapSerial = 1;
}

static void
visionxGLXClientStateCallback(CallbackListPtr *list, void *closure, void *data)
{
    NewClientInfoRec *clientinfo = (NewClientInfoRec *) data;
    ClientPtr client = clientinfo != NULL ? clientinfo->client : NULL;

    (void) list;
    (void) closure;

    if (client != NULL && client->clientState == ClientStateGone)
        visionxGLXCleanupClient(client);
}

static void
visionxGLXSwapReplyHeader(ClientPtr client, CARD16 *sequenceNumber, CARD32 *length)
{
    if (client->swapped) {
        swaps(sequenceNumber);
        swapl(length);
    }
}

static int
visionxGLXSendString(ClientPtr client, const char *value)
{
    size_t n = strlen(value) + 1;
    int length = bytes_to_int32((int) n);
    char *buffer = calloc((size_t) length, 4);
    xVisionXGLXStringReply reply;

    if (buffer == NULL)
        return BadAlloc;
    memcpy(buffer, value, n);

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = (CARD32) length;
    reply.n = (CARD32) n;
    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.n);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, length << 2, buffer);
    free(buffer);
    return Success;
}

static int
visionxGLXSendSingleString(ClientPtr client, const char *value)
{
    size_t n = strlen(value) + 1;
    int length = bytes_to_int32((int) n);
    char *buffer = calloc((size_t) length, 4);
    xVisionXGLXSingleReply reply;

    if (buffer == NULL)
        return BadAlloc;
    memcpy(buffer, value, n);

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = (CARD32) length;
    reply.size = (CARD32) n;
    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.size);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, length << 2, buffer);
    free(buffer);
    return Success;
}

static int
visionxGLXSendSingleValue(ClientPtr client, CARD32 value)
{
    xVisionXGLXSingleReply reply;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.retval = value;
    reply.size = 1;
    reply.pad3 = value;
    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.retval);
        swapl(&reply.size);
        swapl(&reply.pad3);
    }

    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXSendSingleValues(ClientPtr client, const CARD32 *values, CARD32 count)
{
    xVisionXGLXSingleReply reply;
    CARD32 *swappedValues = NULL;

    if (count == 0)
        return visionxGLXSendSingleValue(client, 0);
    if (count == 1)
        return visionxGLXSendSingleValue(client, values[0]);

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = count;
    reply.size = count;

    if (client->swapped) {
        swappedValues = calloc(count, sizeof(CARD32));
        if (swappedValues == NULL)
            return BadAlloc;
        for (CARD32 i = 0; i < count; i++) {
            swappedValues[i] = values[i];
            swapl(&swappedValues[i]);
        }
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.size);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, count * sizeof(CARD32), client->swapped ? swappedValues : values);
    free(swappedValues);
    return Success;
}

static const char *
visionxGLXGLString(CARD32 name)
{
    switch (name) {
    case GL_VENDOR:
        return VISIONX_GL_VENDOR_STRING;
    case GL_RENDERER:
        return VISIONX_GL_RENDERER_STRING;
    case GL_VERSION:
        return VISIONX_GL_VERSION_STRING;
    case GL_EXTENSIONS:
        return VISIONX_GL_EXTENSIONS_STRING;
    default:
        return "";
    }
}

static CARD32
visionxGLXReadCARD32(const void *bytes, Bool swapped)
{
    CARD32 value;

    memcpy(&value, bytes, sizeof(value));
    if (swapped)
        swapl(&value);
    return value;
}

static void
visionxGLXWriteCARD16(void *bytes, CARD16 value, Bool swapped)
{
    if (swapped)
        swaps(&value);
    memcpy(bytes, &value, sizeof(value));
}

static Bool
visionxGLXPaddedLength(size_t byteCount, size_t *paddedLength)
{
    if (paddedLength == NULL || byteCount > SIZE_MAX - 3)
        return FALSE;
    *paddedLength = (byteCount + 3) & ~(size_t) 3;
    return TRUE;
}

static int
visionxGLXExecuteLargeRenderBuffer(ClientPtr client, VisionXGLXContextRecord *context)
{
    CARD32 largeOpcode;
    size_t payloadLength;
    size_t normalLength;
    size_t paddedNormalLength;
    uint8_t *normalCommand;
    Bool captureDrawCalls;

    if (client == NULL ||
        context == NULL ||
        context->largeRenderBuffer == NULL ||
        context->largeRenderLength < 8)
        return BadLength;

    largeOpcode = visionxGLXReadCARD32(context->largeRenderBuffer + 4, client->swapped);
    if (largeOpcode > UINT16_MAX) {
        client->errorValue = largeOpcode;
        return visionxGLXError(GLXBadRenderRequest);
    }

    payloadLength = context->largeRenderLength - 8;
    if (payloadLength > UINT16_MAX - 4) {
        visionxGLXRuntimeLog("GLX large render ignored context=%u opcode=%u bytes=%zu reason=tooLargeForDecoder",
                    (unsigned) context->id,
                    (unsigned) largeOpcode,
                    context->largeRenderLength);
        return Success;
    }

    normalLength = payloadLength + 4;
    if (!visionxGLXPaddedLength(normalLength, &paddedNormalLength) ||
        paddedNormalLength > UINT16_MAX)
        return BadLength;

    normalCommand = calloc(1, paddedNormalLength);
    if (normalCommand == NULL)
        return BadAlloc;

    visionxGLXWriteCARD16(normalCommand, (CARD16) paddedNormalLength, client->swapped);
    visionxGLXWriteCARD16(normalCommand + 2, (CARD16) largeOpcode, client->swapped);
    if (payloadLength > 0)
        memcpy(normalCommand + 4, context->largeRenderBuffer + 8, payloadLength);

    captureDrawCalls = visionxGLXShouldCaptureRender(client, context);
    if (!visionx_ddx_glx_execute_render(visionx_ddx_current_screen(),
                                        context->id,
                                        normalCommand,
                                        paddedNormalLength,
                                        client->swapped ? 1 : 0,
                                        captureDrawCalls ? 1 : 0)) {
        visionxGLXRuntimeLog("GLX large render ignored context=%u opcode=%u bytes=%zu reason=decoderRejected",
                    (unsigned) context->id,
                    (unsigned) largeOpcode,
                    paddedNormalLength);
        free(normalCommand);
        return Success;
    }
    visionxGLXNoteCapturedRender(context, captureDrawCalls);

    free(normalCommand);
    return Success;
}

static WindowPtr
visionxGLXTopLevelForWindow(WindowPtr pWin)
{
    WindowPtr current = pWin;

    while (current != NULL &&
           current->parent != NULL &&
           current->parent->parent != NULL) {
        current = current->parent;
    }

    return current;
}

static void
visionxGLXPopulateWindowDrawableConfig(visionx_glx_drawable_config_t *config,
                                       GLXDrawable drawable,
                                       WindowPtr pWin,
                                       CARD32 visual)
{
    WindowPtr presentation = visionxGLXTopLevelForWindow(pWin);

    memset(config, 0, sizeof(*config));
    config->drawable = drawable;
    config->backing_xid = pWin->drawable.id;
    config->presentation_xid = presentation != NULL ? presentation->drawable.id : pWin->drawable.id;
    config->kind = VISIONX_GLX_DRAWABLE_WINDOW;
    config->visual_id = visual;
    config->width = pWin->drawable.width;
    config->height = pWin->drawable.height;
    config->presentation_x = presentation != NULL ? pWin->drawable.x - presentation->drawable.x : 0;
    config->presentation_y = presentation != NULL ? pWin->drawable.y - presentation->drawable.y : 0;
}

static Bool
visionxGLXWindowHasAncestor(WindowPtr pWin, WindowPtr ancestor)
{
    WindowPtr current = pWin;

    while (current != NULL) {
        if (current == ancestor)
            return TRUE;
        current = current->parent;
    }

    return FALSE;
}

void
visionx_glx_refresh_window_presentation(WindowPtr presentation)
{
    if (presentation == NULL)
        return;

    for (size_t i = 0; i < VISIONX_GLX_MAX_DRAWABLES; i++) {
        VisionXGLXDrawableRecord *record = &visionxGLXDrawables[i];
        WindowPtr pWin = NULL;
        visionx_glx_drawable_config_t config;

        if (!record->inUse)
            continue;
        if (dixLookupWindow(&pWin, record->backing, serverClient, DixGetAttrAccess) != Success)
            continue;
        if (pWin == NULL || !visionxGLXWindowHasAncestor(pWin, presentation))
            continue;

        visionxGLXPopulateWindowDrawableConfig(&config, record->id, pWin, record->visual);
        if (config.presentation_xid == record->backing &&
            config.presentation_x == 0 &&
            config.presentation_y == 0)
            continue;

        visionx_ddx_glx_create_drawable(visionx_ddx_current_screen(), config);
    }
}

static int
visionxGLXEnsureWindowDrawable(ClientPtr client, GLXDrawable drawable, CARD32 visual)
{
    DrawablePtr pDraw = NULL;
    WindowPtr pWin = NULL;
    int rc;
    visionx_glx_drawable_config_t config;

    if (visionxGLXDrawable(drawable) != NULL)
        return Success;

    rc = dixLookupDrawable(&pDraw, drawable, client, 0, DixGetAttrAccess);
    if (rc != Success)
        return rc;
    if (pDraw == NULL || pDraw->type != DRAWABLE_WINDOW)
        return BadMatch;

    pWin = (WindowPtr) pDraw;
    visionxGLXPopulateWindowDrawableConfig(&config, drawable, pWin, visual);

    if (!visionx_ddx_glx_create_drawable(visionx_ddx_current_screen(), config))
        return BadAlloc;

    visionxGLXRememberDrawable(client, drawable, pWin->drawable.id, visual, pWin->drawable.width, pWin->drawable.height);
    return Success;
}

static int
visionxGLXSingleNewList(ClientPtr client)
{
    CARD32 list;
    CARD32 mode;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_FIXED_SIZE(xVisionXGLXSingleReq, 8);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    list = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq), client->swapped);
    mode = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq) + 4, client->swapped);
    if (!visionx_ddx_glx_new_list(visionx_ddx_current_screen(), stuff->contextTag, list, mode))
        return BadValue;

    return Success;
}

static int
visionxGLXSingleEndList(ClientPtr client)
{
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_SIZE_MATCH(xVisionXGLXSingleReq);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    if (!visionx_ddx_glx_end_list(visionx_ddx_current_screen(), stuff->contextTag))
        return BadMatch;

    return Success;
}

static int
visionxGLXSingleDeleteLists(ClientPtr client)
{
    CARD32 list;
    CARD32 range;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_FIXED_SIZE(xVisionXGLXSingleReq, 8);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    list = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq), client->swapped);
    range = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq) + 4, client->swapped);
    if (!visionx_ddx_glx_delete_lists(visionx_ddx_current_screen(), stuff->contextTag, list, range))
        return BadMatch;

    return Success;
}

static int
visionxGLXSingleGenLists(ClientPtr client)
{
    CARD32 range;
    CARD32 base;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_FIXED_SIZE(xVisionXGLXSingleReq, 4);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    range = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq), client->swapped);
    if (range == 0)
        return visionxGLXSendSingleValue(client, 0);

    base = visionx_ddx_glx_gen_lists(visionx_ddx_current_screen(), stuff->contextTag, range);
    return visionxGLXSendSingleValue(client, base);
}

static int
visionxGLXSingleGetError(ClientPtr client)
{
    xVisionXGLXSingleReply reply;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_SIZE_MATCH(xVisionXGLXSingleReq);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.retval = GL_NO_ERROR;
    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.retval);
    }
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXSingleGetIntegerv(ClientPtr client)
{
    CARD32 pname;
    CARD32 values[2] = { 0, 0 };
    CARD32 count = 1;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_FIXED_SIZE(xVisionXGLXSingleReq, 4);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    pname = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq), client->swapped);
    switch (pname) {
    case GL_AUX_BUFFERS:
        values[0] = 0;
        break;
    case GL_MAX_LIGHTS:
        values[0] = 8;
        break;
    case GL_MAX_CLIP_PLANES:
        values[0] = 6;
        break;
    case GL_MAX_TEXTURE_SIZE:
        values[0] = 4096;
        break;
    case GL_MAX_MODELVIEW_STACK_DEPTH:
        values[0] = 32;
        break;
    case GL_MAX_PROJECTION_STACK_DEPTH:
    case GL_MAX_TEXTURE_STACK_DEPTH:
        values[0] = 10;
        break;
    case GL_MAX_VIEWPORT_DIMS:
        values[0] = 16384;
        values[1] = 16384;
        count = 2;
        break;
    case GL_SUBPIXEL_BITS:
        values[0] = 4;
        break;
    case GL_RED_BITS:
    case GL_GREEN_BITS:
    case GL_BLUE_BITS:
    case GL_ALPHA_BITS:
        values[0] = 8;
        break;
    case GL_DEPTH_BITS:
        values[0] = 24;
        break;
    case GL_STENCIL_BITS:
        values[0] = 8;
        break;
    case GL_ACCUM_RED_BITS:
    case GL_ACCUM_GREEN_BITS:
    case GL_ACCUM_BLUE_BITS:
    case GL_ACCUM_ALPHA_BITS:
        values[0] = 0;
        break;
    case GL_MAX_TEXTURE_UNITS:
        values[0] = 1;
        break;
    default:
        values[0] = 0;
        break;
    }

    return visionxGLXSendSingleValues(client, values, count);
}

static int
visionxGLXSingleGetString(ClientPtr client)
{
    CARD32 name;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_FIXED_SIZE(xVisionXGLXSingleReq, 4);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    name = visionxGLXReadCARD32((const uint8_t *) stuff + sizeof(xVisionXGLXSingleReq), client->swapped);
    return visionxGLXSendSingleString(client, visionxGLXGLString(name));
}

static int
visionxGLXSingleFinish(ClientPtr client)
{
    xVisionXGLXSingleReply reply;
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_SIZE_MATCH(xVisionXGLXSingleReq);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXSingleFlush(ClientPtr client)
{
    REQUEST(xVisionXGLXSingleReq);
    REQUEST_SIZE_MATCH(xVisionXGLXSingleReq);

    if (client->swapped)
        swapl(&stuff->contextTag);
    if (stuff->contextTag != 0 && visionxGLXContext(stuff->contextTag) == NULL)
        return BadMatch;
    return Success;
}

static int
visionxGLXRender(ClientPtr client)
{
    VisionXGLXContextRecord *context;
    VisionXGLXDrawableRecord *drawable;
    GLXContextTag contextTag;
    const uint8_t *commands;
    size_t commandLength;
    Bool captureDrawCalls;
    static uint64_t renderRequestLogCount;
    uint64_t renderRequestLogIndex;
    REQUEST(xVisionXGLXRenderReq);
    REQUEST_AT_LEAST_SIZE(xVisionXGLXRenderReq);

    contextTag = stuff->contextTag;
    if (client->swapped)
        swapl(&contextTag);

    context = visionxGLXContext(contextTag);
    if (context == NULL)
        return BadMatch;

    drawable = visionxGLXDrawable(context->currentDrawable);
    if (visionxGLXSleepClientForPendingSwap(client, drawable, TRUE))
        return Success;

    renderRequestLogIndex = ++renderRequestLogCount;
    if (renderRequestLogIndex <= 24 || (renderRequestLogIndex % 24000) == 0) {
        visionxGLXRuntimeLog("GLX render request context=%u drawable=%u pendingSerial=%llu requestLength=%u count=%llu",
                    (unsigned) contextTag,
                    (unsigned) context->currentDrawable,
                    (unsigned long long) (drawable == NULL ? 0 : drawable->pendingSwapSerial),
                    (unsigned) stuff->length,
                    (unsigned long long) renderRequestLogIndex);
    }

    if (visionxGLXShouldDropRender(client, context))
        return Success;

    commandLength = ((size_t) stuff->length << 2) - sizeof(xVisionXGLXRenderReq);
    if (commandLength == 0)
        return Success;

    commands = (const uint8_t *) stuff + sizeof(xVisionXGLXRenderReq);
    captureDrawCalls = visionxGLXShouldCaptureRender(client, context);
    if (!visionx_ddx_glx_execute_render(visionx_ddx_current_screen(),
                                        contextTag,
                                        commands,
                                        commandLength,
                                        client->swapped ? 1 : 0,
                                        captureDrawCalls ? 1 : 0)) {
        client->errorValue = contextTag;
        visionxGLXRuntimeLog("GLX render rejected context=%u commandBytes=%zu", (unsigned) contextTag, commandLength);
        return visionxGLXError(GLXBadRenderRequest);
    }
    visionxGLXNoteCapturedRender(context, captureDrawCalls);
    if (renderRequestLogIndex <= 24 || (renderRequestLogIndex % 24000) == 0) {
        visionxGLXRuntimeLog("GLX render completed context=%u commandBytes=%zu count=%llu",
                    (unsigned) contextTag,
                    commandLength,
                    (unsigned long long) renderRequestLogIndex);
    }
    return Success;
}

static int
visionxGLXRenderLarge(ClientPtr client)
{
    VisionXGLXContextRecord *context;
    VisionXGLXDrawableRecord *drawable;
    GLXContextTag contextTag;
    CARD16 requestNumber;
    CARD16 requestTotal;
    CARD32 dataBytes;
    size_t requestBytes;
    size_t paddedDataBytes;
    const uint8_t *commands;
    int result;
    REQUEST(xVisionXGLXRenderLargeReq);
    REQUEST_AT_LEAST_SIZE(xVisionXGLXRenderLargeReq);

    contextTag = stuff->contextTag;
    requestNumber = stuff->requestNumber;
    requestTotal = stuff->requestTotal;
    dataBytes = stuff->dataBytes;
    if (client->swapped) {
        swapl(&contextTag);
        swaps(&requestNumber);
        swaps(&requestTotal);
        swapl(&dataBytes);
    }

    context = visionxGLXContext(contextTag);
    if (context == NULL)
        return BadMatch;

    drawable = visionxGLXDrawable(context->currentDrawable);
    if (visionxGLXSleepClientForPendingSwap(client, drawable, TRUE))
        return Success;

    if (!visionxGLXPaddedLength((size_t) dataBytes, &paddedDataBytes))
        return BadLength;
    requestBytes = (size_t) stuff->length << 2;
    if (requestBytes != sizeof(xVisionXGLXRenderLargeReq) + paddedDataBytes) {
        client->errorValue = stuff->length;
        visionxGLXResetLargeRender(context);
        return BadLength;
    }

    if (requestNumber == 0 || requestTotal == 0 || requestNumber > requestTotal) {
        client->errorValue = requestNumber;
        visionxGLXResetLargeRender(context);
        return visionxGLXError(GLXBadLargeRequest);
    }

    if (visionxGLXShouldDropRender(client, context)) {
        visionxGLXResetLargeRender(context);
        return Success;
    }

    commands = (const uint8_t *) stuff + sizeof(xVisionXGLXRenderLargeReq);
    if (requestNumber == 1) {
        visionxGLXResetLargeRender(context);
        context->largeRenderRequestsTotal = requestTotal;
    } else {
        if (context->largeRenderRequestsSoFar == 0 ||
            requestNumber != context->largeRenderRequestsSoFar + 1 ||
            requestTotal != context->largeRenderRequestsTotal) {
            client->errorValue = requestNumber;
            visionxGLXResetLargeRender(context);
            return visionxGLXError(GLXBadLargeRequest);
        }
    }

    if (!visionxGLXAppendLargeRenderBytes(context, commands, (size_t) dataBytes)) {
        visionxGLXResetLargeRender(context);
        return BadAlloc;
    }
    context->largeRenderRequestsSoFar = requestNumber;

    if (requestNumber != requestTotal)
        return Success;

    result = visionxGLXExecuteLargeRenderBuffer(client, context);
    visionxGLXResetLargeRender(context);
    return result;
}

static int
visionxGLXQueryVersion(ClientPtr client)
{
    xVisionXGLXQueryVersionReply reply;
    REQUEST(xVisionXGLXQueryVersionReq);
    REQUEST_SIZE_MATCH(xVisionXGLXQueryVersionReq);

    if (client->swapped) {
        swapl(&stuff->majorVersion);
        swapl(&stuff->minorVersion);
    }

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.majorVersion = VISIONX_GLX_MAJOR_VERSION;
    reply.minorVersion = VISIONX_GLX_MINOR_VERSION;
    visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
    if (client->swapped) {
        swapl(&reply.majorVersion);
        swapl(&reply.minorVersion);
    }
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXCreateContext(ClientPtr client)
{
    CARD32 visualID;
    visionx_glx_context_config_t config;
    REQUEST(xVisionXGLXCreateContextReq);
    REQUEST_SIZE_MATCH(xVisionXGLXCreateContextReq);

    if (client->swapped) {
        swapl(&stuff->context);
        swapl(&stuff->visual);
        swapl(&stuff->screen);
        swapl(&stuff->shareList);
    }

    visualID = visionxGLXVisualID(stuff->screen);
    if (visualID == 0)
        return BadValue;
    if (stuff->visual != visualID)
        return BadMatch;
    if (visionxGLXContext(stuff->context) != NULL)
        return BadIDChoice;

    memset(&config, 0, sizeof(config));
    config.context = stuff->context;
    config.visual_id = visualID;
    config.share_context = stuff->shareList;
    config.has_share_context = stuff->shareList != 0 ? 1 : 0;
    config.direct = stuff->isDirect ? 1 : 0;
    if (!visionx_ddx_glx_create_context(visionx_ddx_current_screen(), config))
        return BadMatch;

    visionxGLXRememberContext(client, stuff->context, stuff->screen, visualID, VISIONX_GLX_FBCONFIG_ID, stuff->shareList, GLX_RGBA_TYPE);
    return Success;
}

static int
visionxGLXDestroyContext(ClientPtr client)
{
    REQUEST(xVisionXGLXDestroyContextReq);
    REQUEST_SIZE_MATCH(xVisionXGLXDestroyContextReq);

    if (client->swapped)
        swapl(&stuff->context);

    visionx_ddx_glx_destroy_context(visionx_ddx_current_screen(), stuff->context);
    visionxGLXForgetContext(stuff->context);
    return Success;
}

static int
visionxGLXMakeCurrent(ClientPtr client)
{
    xVisionXGLXMakeCurrentReply reply;
    VisionXGLXContextRecord *context;
    VisionXGLXContextRecord *oldContext;
    GLXDrawable drawableID;
    GLXContextID contextID;
    GLXContextTag oldContextTag;
    int rc;
    REQUEST(xVisionXGLXMakeCurrentReq);
    REQUEST_SIZE_MATCH(xVisionXGLXMakeCurrentReq);

    drawableID = stuff->drawable;
    contextID = stuff->context;
    oldContextTag = stuff->oldContextTag;
    if (client->swapped) {
        swapl(&drawableID);
        swapl(&contextID);
        swapl(&oldContextTag);
    }

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;

    if (contextID == 0) {
        oldContext = visionxGLXContext(oldContextTag);
        if (oldContext != NULL)
            oldContext->currentDrawable = 0;
        visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
        WriteToClient(client, sizeof(reply), &reply);
        return Success;
    }

    context = visionxGLXContext(contextID);
    if (context == NULL)
        return BadMatch;

    rc = visionxGLXEnsureWindowDrawable(client, drawableID, context->visual);
    if (rc != Success)
        return rc;

    if (!visionx_ddx_glx_make_current(visionx_ddx_current_screen(), contextID, drawableID))
        return BadMatch;

    oldContext = visionxGLXContext(oldContextTag);
    if (oldContext != NULL && oldContext != context)
        oldContext->currentDrawable = 0;
    context->currentDrawable = drawableID;

    reply.contextTag = contextID;
    visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
    if (client->swapped)
        swapl(&reply.contextTag);
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXIsDirect(ClientPtr client)
{
    xVisionXGLXIsDirectReply reply;
    REQUEST(xVisionXGLXIsDirectReq);
    REQUEST_SIZE_MATCH(xVisionXGLXIsDirectReq);

    if (client->swapped)
        swapl(&stuff->context);

    if (visionxGLXContext(stuff->context) == NULL)
        return BadMatch;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.isDirect = FALSE;
    visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXSwapBuffers(ClientPtr client)
{
    VisionXGLXContextRecord *context = NULL;
    VisionXGLXDrawableRecord *drawable;
    GLXContextTag contextTag;
    GLXDrawable drawableID;
    uint64_t swapSerial;
    Bool shouldPresent;
    int rc;
    static uint64_t suppressedSwapLogCount;
    REQUEST(xVisionXGLXSwapBuffersReq);
    REQUEST_SIZE_MATCH(xVisionXGLXSwapBuffersReq);

    contextTag = stuff->contextTag;
    drawableID = stuff->drawable;
    if (client->swapped) {
        swapl(&contextTag);
        swapl(&drawableID);
    }

    if (contextTag != 0) {
        context = visionxGLXContext(contextTag);
        if (context == NULL)
            return BadMatch;
    }

    drawable = visionxGLXDrawable(drawableID);
    if (drawable == NULL) {
        if (context == NULL)
            return BadMatch;
        rc = visionxGLXEnsureWindowDrawable(client, drawableID, context->visual);
        if (rc != Success)
            return rc;
        drawable = visionxGLXDrawable(drawableID);
    }
    if (drawable == NULL)
        return BadMatch;

    if (visionxGLXSleepClientForPendingSwap(client, drawable, TRUE))
        return Success;

    if (drawable->suppressedFrameCapture) {
        drawable->suppressedFrameCapture = FALSE;
        suppressedSwapLogCount++;
        if (suppressedSwapLogCount <= 12 || (suppressedSwapLogCount % 240) == 0) {
            visionxGLXRuntimeLog("GLX swap skipped suppressed frame drawable=%u count=%llu",
                        (unsigned) drawableID,
                        (unsigned long long) suppressedSwapLogCount);
        }
        return Success;
    }

    swapSerial = visionxGLXAllocateSwapSerial();
    shouldPresent = visionxGLXShouldPresentFrame(client, drawable, swapSerial);
    if (!shouldPresent) {
        int discardedRequests = 0;
        static uint64_t bufferedDiscardLogCount;
        static uint64_t bufferedDiscardTotal;

        if (visionxGLXDiscardSkippedFramesEnabled())
            discardedRequests = visionxGLXDiscardBufferedFrameRequests(client);
        if (discardedRequests > 0) {
            bufferedDiscardLogCount++;
            bufferedDiscardTotal += (uint64_t) discardedRequests;
            if (bufferedDiscardLogCount <= 12 || (bufferedDiscardLogCount % 240) == 0) {
                visionxGLXRuntimeLog("GLX buffered frame requests discarded drawable=%u requests=%d total=%llu count=%llu",
                            (unsigned) drawableID,
                            discardedRequests,
                            (unsigned long long) bufferedDiscardTotal,
                            (unsigned long long) bufferedDiscardLogCount);
            }
        }
        visionxGLXDidSwapFrame(drawable, FALSE);
        if (visionxGLXMaybeSleepClientForFramePace(client, drawable, FALSE))
            return Success;
        if (visionxGLXFramePaceIntervalUsec() == 0)
            visionxGLXPaceSkippedSwap();
        return Success;
    }

    if (visionxGLXBackpressureEnabled())
        visionxGLXTrackPendingSwap(drawable, swapSerial);
    if (!visionx_ddx_glx_swap_buffers(visionx_ddx_current_screen(), contextTag, drawableID, swapSerial, 1)) {
        if (visionxGLXBackpressureEnabled()) {
            visionxGLXRemovePendingSwap(drawable, swapSerial);
            visionxGLXSignalSwapWaiters(drawable);
        }
        return BadMatch;
    }
    visionxGLXDidSwapFrame(drawable, TRUE);
    if (visionxGLXMaybeSleepClientForFramePace(client, drawable, FALSE))
        return Success;
    visionxGLXSleepClientForPendingSwap(client, drawable, FALSE);

    return Success;
}

static int
visionxGLXGetVisualConfigs(ClientPtr client)
{
    CARD32 visualID;
    CARD32 props[VISIONX_GLX_VISUAL_PROPS];
    xVisionXGLXGetVisualConfigsReply reply;
    REQUEST(xVisionXGLXGetVisualConfigsReq);
    REQUEST_SIZE_MATCH(xVisionXGLXGetVisualConfigsReq);

    if (client->swapped)
        swapl(&stuff->screen);

    visualID = visionxGLXVisualID(stuff->screen);
    if (visualID == 0)
        return BadValue;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = VISIONX_GLX_VISUAL_PROPS;
    reply.numVisuals = 1;
    reply.numProps = VISIONX_GLX_VISUAL_PROPS;

    memset(props, 0, sizeof(props));
    props[0] = visualID;
    props[1] = X_TRUE_COLOR;
    props[2] = TRUE;
    props[3] = 8;
    props[4] = 8;
    props[5] = 8;
    props[6] = 8;
    props[7] = 0;
    props[8] = 0;
    props[9] = 0;
    props[10] = 0;
    props[11] = TRUE;
    props[12] = FALSE;
    props[13] = 32;
    props[14] = 24;
    props[15] = 8;
    props[16] = 0;
    props[17] = 0;
    props[18] = GLX_VISUAL_CAVEAT_EXT;
    props[19] = GLX_NONE;
    props[20] = GLX_TRANSPARENT_TYPE;
    props[21] = GLX_NONE;
    props[22] = GLX_TRANSPARENT_RED_VALUE;
    props[23] = 0;
    props[24] = GLX_TRANSPARENT_GREEN_VALUE;
    props[25] = 0;
    props[26] = GLX_TRANSPARENT_BLUE_VALUE;
    props[27] = 0;
    props[28] = GLX_TRANSPARENT_ALPHA_VALUE;
    props[29] = 0;
    props[30] = GLX_TRANSPARENT_INDEX_VALUE;
    props[31] = 0;
    props[32] = GLX_SAMPLES_SGIS;
    props[33] = 0;
    props[34] = GLX_SAMPLE_BUFFERS_SGIS;
    props[35] = 0;
    props[36] = GLX_VISUAL_SELECT_GROUP_SGIX;
    props[37] = 0;

    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.numVisuals);
        swapl(&reply.numProps);
        for (size_t i = 0; i < VISIONX_GLX_VISUAL_PROPS; i++)
            swapl(&props[i]);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, sizeof(props), props);
    return Success;
}

static void
visionxGLXWritePair(CARD32 *props, size_t *index, CARD32 attribute, CARD32 value)
{
    props[(*index)++] = attribute;
    props[(*index)++] = value;
}

static void
visionxGLXBuildFBConfig(CARD32 visualID, CARD32 *props)
{
    size_t i = 0;

    memset(props, 0, VISIONX_GLX_FBCONFIG_WORDS * sizeof(CARD32));
    visionxGLXWritePair(props, &i, GLX_VISUAL_ID, visualID);
    visionxGLXWritePair(props, &i, GLX_FBCONFIG_ID, VISIONX_GLX_FBCONFIG_ID);
    visionxGLXWritePair(props, &i, GLX_X_RENDERABLE, TRUE);
    visionxGLXWritePair(props, &i, GLX_RGBA, TRUE);
    visionxGLXWritePair(props, &i, GLX_RENDER_TYPE, GLX_RGBA_BIT);
    visionxGLXWritePair(props, &i, GLX_DOUBLEBUFFER, TRUE);
    visionxGLXWritePair(props, &i, GLX_STEREO, FALSE);
    visionxGLXWritePair(props, &i, GLX_BUFFER_SIZE, 32);
    visionxGLXWritePair(props, &i, GLX_LEVEL, 0);
    visionxGLXWritePair(props, &i, GLX_AUX_BUFFERS, 0);
    visionxGLXWritePair(props, &i, GLX_RED_SIZE, 8);
    visionxGLXWritePair(props, &i, GLX_GREEN_SIZE, 8);
    visionxGLXWritePair(props, &i, GLX_BLUE_SIZE, 8);
    visionxGLXWritePair(props, &i, GLX_ALPHA_SIZE, 8);
    visionxGLXWritePair(props, &i, GLX_ACCUM_RED_SIZE, 0);
    visionxGLXWritePair(props, &i, GLX_ACCUM_GREEN_SIZE, 0);
    visionxGLXWritePair(props, &i, GLX_ACCUM_BLUE_SIZE, 0);
    visionxGLXWritePair(props, &i, GLX_ACCUM_ALPHA_SIZE, 0);
    visionxGLXWritePair(props, &i, GLX_DEPTH_SIZE, 24);
    visionxGLXWritePair(props, &i, GLX_STENCIL_SIZE, 8);
    visionxGLXWritePair(props, &i, GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR);
    visionxGLXWritePair(props, &i, GLX_CONFIG_CAVEAT, GLX_NONE);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_TYPE, GLX_NONE);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_RED_VALUE, 0);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_GREEN_VALUE, 0);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_BLUE_VALUE, 0);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_ALPHA_VALUE, 0);
    visionxGLXWritePair(props, &i, GLX_TRANSPARENT_INDEX_VALUE, 0);
    visionxGLXWritePair(props, &i, GLX_SWAP_METHOD_OML, GLX_DONT_CARE);
    visionxGLXWritePair(props, &i, GLX_SAMPLES_SGIS, 0);
    visionxGLXWritePair(props, &i, GLX_SAMPLE_BUFFERS_SGIS, 0);
    visionxGLXWritePair(props, &i, GLX_VISUAL_SELECT_GROUP_SGIX, 0);
    visionxGLXWritePair(props, &i, GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT | GLX_PIXMAP_BIT);
    visionxGLXWritePair(props, &i, GLX_BIND_TO_TEXTURE_RGB_EXT, FALSE);
    visionxGLXWritePair(props, &i, GLX_BIND_TO_TEXTURE_RGBA_EXT, FALSE);
    visionxGLXWritePair(props, &i, GLX_BIND_TO_MIPMAP_TEXTURE_EXT, FALSE);
    visionxGLXWritePair(props, &i, GLX_BIND_TO_TEXTURE_TARGETS_EXT, 0);
    visionxGLXWritePair(props, &i, GLX_Y_INVERTED_EXT, GLX_DONT_CARE);
}

static int
visionxGLXGetFBConfigs(ClientPtr client)
{
    CARD32 visualID;
    CARD32 props[VISIONX_GLX_FBCONFIG_WORDS];
    xVisionXGLXGetFBConfigsReply reply;
    REQUEST(xVisionXGLXGetFBConfigsReq);
    REQUEST_SIZE_MATCH(xVisionXGLXGetFBConfigsReq);

    if (client->swapped)
        swapl(&stuff->screen);

    visualID = visionxGLXVisualID(stuff->screen);
    if (visualID == 0)
        return BadValue;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = VISIONX_GLX_FBCONFIG_WORDS;
    reply.numFBConfigs = 1;
    reply.numAttribs = VISIONX_GLX_FBCONFIG_ATTRIBS;

    visionxGLXBuildFBConfig(visualID, props);

    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.numFBConfigs);
        swapl(&reply.numAttribs);
        for (size_t i = 0; i < VISIONX_GLX_FBCONFIG_WORDS; i++)
            swapl(&props[i]);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, sizeof(props), props);
    return Success;
}

static int
visionxGLXCreateNewContext(ClientPtr client)
{
    CARD32 visualID;
    visionx_glx_context_config_t config;
    REQUEST(xVisionXGLXCreateNewContextReq);
    REQUEST_SIZE_MATCH(xVisionXGLXCreateNewContextReq);

    if (client->swapped) {
        swapl(&stuff->context);
        swapl(&stuff->fbconfig);
        swapl(&stuff->screen);
        swapl(&stuff->renderType);
        swapl(&stuff->shareList);
    }

    visualID = visionxGLXVisualID(stuff->screen);
    if (visualID == 0)
        return BadValue;
    if (stuff->fbconfig != VISIONX_GLX_FBCONFIG_ID || stuff->renderType != GLX_RGBA_TYPE)
        return BadMatch;
    if (visionxGLXContext(stuff->context) != NULL)
        return BadIDChoice;

    memset(&config, 0, sizeof(config));
    config.context = stuff->context;
    config.visual_id = visualID;
    config.share_context = stuff->shareList;
    config.has_share_context = stuff->shareList != 0 ? 1 : 0;
    config.direct = stuff->isDirect ? 1 : 0;
    if (!visionx_ddx_glx_create_context(visionx_ddx_current_screen(), config))
        return BadMatch;

    visionxGLXRememberContext(client, stuff->context, stuff->screen, visualID, stuff->fbconfig, stuff->shareList, stuff->renderType);
    return Success;
}

static int
visionxGLXQueryContext(ClientPtr client)
{
    CARD32 props[10];
    xVisionXGLXQueryContextReply reply;
    VisionXGLXContextRecord *context;
    REQUEST(xVisionXGLXQueryContextReq);
    REQUEST_SIZE_MATCH(xVisionXGLXQueryContextReq);

    if (client->swapped)
        swapl(&stuff->context);

    context = visionxGLXContext(stuff->context);
    if (context == NULL)
        return BadMatch;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = 10;
    reply.n = 5;

    props[0] = GLX_SHARE_CONTEXT_EXT;
    props[1] = context->shareList;
    props[2] = GLX_VISUAL_ID_EXT;
    props[3] = context->visual;
    props[4] = GLX_SCREEN_EXT;
    props[5] = context->screen;
    props[6] = GLX_FBCONFIG_ID;
    props[7] = context->fbconfig;
    props[8] = GLX_RENDER_TYPE;
    props[9] = context->renderType;

    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.n);
        for (size_t i = 0; i < 10; i++)
            swapl(&props[i]);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, sizeof(props), props);
    return Success;
}

static int
visionxGLXMakeContextCurrent(ClientPtr client)
{
    xVisionXGLXMakeCurrentReply reply;
    VisionXGLXContextRecord *context;
    VisionXGLXContextRecord *oldContext;
    GLXContextTag oldContextTag;
    GLXDrawable drawableID;
    GLXDrawable readDrawableID;
    GLXContextID contextID;
    int rc;
    REQUEST(xVisionXGLXMakeContextCurrentReq);
    REQUEST_SIZE_MATCH(xVisionXGLXMakeContextCurrentReq);

    oldContextTag = stuff->oldContextTag;
    drawableID = stuff->drawable;
    readDrawableID = stuff->readDrawable;
    contextID = stuff->context;
    if (client->swapped) {
        swapl(&oldContextTag);
        swapl(&drawableID);
        swapl(&readDrawableID);
        swapl(&contextID);
    }

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;

    if (contextID == 0) {
        oldContext = visionxGLXContext(oldContextTag);
        if (oldContext != NULL)
            oldContext->currentDrawable = 0;
        visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
        WriteToClient(client, sizeof(reply), &reply);
        return Success;
    }

    if (readDrawableID != 0 && readDrawableID != drawableID)
        return BadMatch;

    context = visionxGLXContext(contextID);
    if (context == NULL)
        return BadMatch;

    rc = visionxGLXEnsureWindowDrawable(client, drawableID, context->visual);
    if (rc != Success)
        return rc;

    if (!visionx_ddx_glx_make_current(visionx_ddx_current_screen(), contextID, drawableID))
        return BadMatch;

    oldContext = visionxGLXContext(oldContextTag);
    if (oldContext != NULL && oldContext != context)
        oldContext->currentDrawable = 0;
    context->currentDrawable = drawableID;

    reply.contextTag = contextID;
    visionxGLXSwapReplyHeader(client, &reply.sequenceNumber, &reply.length);
    if (client->swapped)
        swapl(&reply.contextTag);
    WriteToClient(client, sizeof(reply), &reply);
    return Success;
}

static int
visionxGLXCreateWindow(ClientPtr client)
{
    CARD32 visualID;
    DrawablePtr pDraw = NULL;
    WindowPtr pWin = NULL;
    int rc;
    visionx_glx_drawable_config_t config;
    REQUEST(xVisionXGLXCreateWindowReq);
    REQUEST_AT_LEAST_SIZE(xVisionXGLXCreateWindowReq);

    if (client->swapped) {
        swapl(&stuff->screen);
        swapl(&stuff->fbconfig);
        swapl(&stuff->window);
        swapl(&stuff->glxWindow);
        swapl(&stuff->numAttribs);
    }
    if (stuff->numAttribs > (UINT32_MAX >> 3))
        return BadValue;
    REQUEST_FIXED_SIZE(xVisionXGLXCreateWindowReq, stuff->numAttribs << 3);

    visualID = visionxGLXVisualID(stuff->screen);
    if (visualID == 0)
        return BadValue;
    if (stuff->fbconfig != VISIONX_GLX_FBCONFIG_ID)
        return BadMatch;
    if (visionxGLXDrawable(stuff->glxWindow) != NULL)
        return BadIDChoice;

    rc = dixLookupDrawable(&pDraw, stuff->window, client, 0, DixGetAttrAccess);
    if (rc != Success)
        return rc;
    if (pDraw == NULL || pDraw->type != DRAWABLE_WINDOW)
        return BadWindow;

    pWin = (WindowPtr) pDraw;
    visionxGLXPopulateWindowDrawableConfig(&config, stuff->glxWindow, pWin, visualID);

    if (!visionx_ddx_glx_create_drawable(visionx_ddx_current_screen(), config))
        return BadAlloc;

    visionxGLXRememberDrawable(client, stuff->glxWindow, pWin->drawable.id, visualID, pWin->drawable.width, pWin->drawable.height);
    return Success;
}

static int
visionxGLXDestroyWindow(ClientPtr client)
{
    REQUEST(xVisionXGLXDestroyWindowReq);
    REQUEST_AT_LEAST_SIZE(xVisionXGLXDestroyWindowReq);

    if (client->swapped)
        swapl(&stuff->glxWindow);

    visionx_ddx_glx_destroy_drawable(visionx_ddx_current_screen(), stuff->glxWindow);
    visionxGLXForgetDrawable(stuff->glxWindow);
    return Success;
}

static int
visionxGLXGetDrawableAttributes(ClientPtr client)
{
    CARD32 props[6];
    xVisionXGLXGetDrawableAttributesReply reply;
    VisionXGLXDrawableRecord *drawable;
    REQUEST(xVisionXGLXGetDrawableAttributesReq);
    REQUEST_SIZE_MATCH(xVisionXGLXGetDrawableAttributesReq);

    if (client->swapped)
        swapl(&stuff->drawable);

    drawable = visionxGLXDrawable(stuff->drawable);
    if (drawable == NULL)
        return BadMatch;

    memset(&reply, 0, sizeof(reply));
    reply.type = X_Reply;
    reply.sequenceNumber = client->sequence;
    reply.length = 6;
    reply.numAttribs = 3;

    props[0] = GLX_WIDTH;
    props[1] = drawable->width;
    props[2] = GLX_HEIGHT;
    props[3] = drawable->height;
    props[4] = GLX_EVENT_MASK;
    props[5] = 0;

    if (client->swapped) {
        swaps(&reply.sequenceNumber);
        swapl(&reply.length);
        swapl(&reply.numAttribs);
        for (size_t i = 0; i < 6; i++)
            swapl(&props[i]);
    }

    WriteToClient(client, sizeof(reply), &reply);
    WriteToClient(client, sizeof(props), props);
    return Success;
}

static int
visionxGLXQueryExtensionsString(ClientPtr client)
{
    REQUEST(xVisionXGLXQueryExtensionsStringReq);
    REQUEST_SIZE_MATCH(xVisionXGLXQueryExtensionsStringReq);
    if (client->swapped)
        swapl(&stuff->screen);
    if (visionxGLXVisualID(stuff->screen) == 0)
        return BadValue;
    return visionxGLXSendString(client, "");
}

static int
visionxGLXQueryServerString(ClientPtr client)
{
    const char *value;
    REQUEST(xVisionXGLXQueryServerStringReq);
    REQUEST_SIZE_MATCH(xVisionXGLXQueryServerStringReq);

    if (client->swapped) {
        swapl(&stuff->screen);
        swapl(&stuff->name);
    }

    if (visionxGLXVisualID(stuff->screen) == 0)
        return BadValue;

    switch (stuff->name) {
    case GLX_VENDOR:
        value = "UHF X11 VisionGL";
        break;
    case GLX_VERSION:
        value = "1.3";
        break;
    case GLX_EXTENSIONS:
        value = "";
        break;
    default:
        return BadValue;
    }
    return visionxGLXSendString(client, value);
}

static int
visionxGLXClientInfo(ClientPtr client)
{
    REQUEST(xVisionXGLXClientInfoReq);
    REQUEST_AT_LEAST_SIZE(xVisionXGLXClientInfoReq);
    if (client->swapped) {
        swapl(&stuff->major);
        swapl(&stuff->minor);
        swapl(&stuff->numbytes);
    }
    return Success;
}

static int
visionxGLXDispatch(ClientPtr client)
{
    REQUEST(xReq);

    switch (stuff->data) {
    case X_GLsop_NewList:
        return visionxGLXSingleNewList(client);
    case X_GLsop_EndList:
        return visionxGLXSingleEndList(client);
    case X_GLsop_DeleteLists:
        return visionxGLXSingleDeleteLists(client);
    case X_GLsop_GenLists:
        return visionxGLXSingleGenLists(client);
    case X_GLsop_Finish:
        return visionxGLXSingleFinish(client);
    case X_GLsop_GetError:
        return visionxGLXSingleGetError(client);
    case X_GLsop_GetIntegerv:
        return visionxGLXSingleGetIntegerv(client);
    case X_GLsop_GetString:
        return visionxGLXSingleGetString(client);
    case X_GLsop_Flush:
        return visionxGLXSingleFlush(client);
    case X_GLXCreateContext:
        return visionxGLXCreateContext(client);
    case X_GLXDestroyContext:
        return visionxGLXDestroyContext(client);
    case X_GLXMakeCurrent:
        return visionxGLXMakeCurrent(client);
    case X_GLXIsDirect:
        return visionxGLXIsDirect(client);
    case X_GLXQueryVersion:
        return visionxGLXQueryVersion(client);
    case X_GLXWaitGL:
    case X_GLXWaitX:
        return Success;
    case X_GLXSwapBuffers:
        return visionxGLXSwapBuffers(client);
    case X_GLXGetVisualConfigs:
        return visionxGLXGetVisualConfigs(client);
    case X_GLXGetFBConfigs:
        return visionxGLXGetFBConfigs(client);
    case X_GLXCreateNewContext:
        return visionxGLXCreateNewContext(client);
    case X_GLXQueryContext:
        return visionxGLXQueryContext(client);
    case X_GLXMakeContextCurrent:
        return visionxGLXMakeContextCurrent(client);
    case X_GLXGetDrawableAttributes:
        return visionxGLXGetDrawableAttributes(client);
    case X_GLXCreateWindow:
        return visionxGLXCreateWindow(client);
    case X_GLXDestroyWindow:
        return visionxGLXDestroyWindow(client);
    case X_GLXQueryExtensionsString:
        return visionxGLXQueryExtensionsString(client);
    case X_GLXQueryServerString:
        return visionxGLXQueryServerString(client);
    case X_GLXClientInfo:
        return visionxGLXClientInfo(client);
    case X_GLXRender:
        return visionxGLXRender(client);
    case X_GLXRenderLarge:
        return visionxGLXRenderLarge(client);
    default:
        return BadRequest;
    }
}

static int
visionxGLXSwappedDispatch(ClientPtr client)
{
    REQUEST(xReq);
    swaps(&stuff->length);
    return visionxGLXDispatch(client);
}

static void
visionxGLXCloseDown(ExtensionEntry *extension)
{
    (void) extension;
    visionxGLXCleanupAll();
    visionxGLXCloseSwapWakePipe();
    if (visionxGLXClientCallbackRegistered) {
        DeleteCallback(&ClientStateCallback, visionxGLXClientStateCallback, NULL);
        visionxGLXClientCallbackRegistered = FALSE;
    }
}

static unsigned short
visionxGLXMinorOpcode(ClientPtr client)
{
    xReq *req = (xReq *) client->requestBuffer;
    return req->data;
}

void
VisionXGLXExtensionInit(void)
{
    if (!visionxGLXEnabled()) {
        ErrorF("VisionX GLX: experimental provider disabled\n");
        return;
    }

    visionxGLXExtension = AddExtension(
        "GLX",
        0,
        16,
        visionxGLXDispatch,
        visionxGLXSwappedDispatch,
        visionxGLXCloseDown,
        visionxGLXMinorOpcode
    );

    if (visionxGLXExtension == NULL)
        ErrorF("VisionX GLX: AddExtension failed\n");
    else {
        (void) visionxGLXOpenSwapWakePipe();
        if (!visionxGLXClientCallbackRegistered) {
            if (AddCallback(&ClientStateCallback, visionxGLXClientStateCallback, NULL))
                visionxGLXClientCallbackRegistered = TRUE;
            else
                ErrorF("VisionX GLX: failed to register client cleanup callback\n");
        }
        ErrorF("VisionX GLX: experimental provider enabled requestBase=%d errorBase=%d\n",
               visionxGLXExtension->base,
               visionxGLXExtension->errorBase);
    }
}
