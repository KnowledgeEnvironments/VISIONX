// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

/*
 * X11 ProVision hw/visionx DDX integration.
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

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <X11/X.h>
#include <X11/Xatom.h>
#include <X11/Xproto.h>
#include <X11/Xos.h>

#include "CXOrgBridge/visionx_ddx.h"
#include "callback.h"
#include "colormapst.h"
#ifdef COMPOSITE
#include "compint.h"
#endif
#include "damage.h"
#include "dix.h"
#include "fb.h"
#include "globals.h"
#include "mipointer.h"
#include "micmap.h"
#include "os.h"
#include "property.h"
#include "propertyst.h"
#include "pixmapstr.h"
#include "randrstr.h"
#include "regionstr.h"
#include "scrnintstr.h"
#include "servermd.h"
#include "windowstr.h"

#define VISIONX_DEFAULT_WIDTH 1280
#define VISIONX_DEFAULT_HEIGHT 720
#define VISIONX_DEFAULT_DEPTH 24
#define VISIONX_HINT_P_MIN_SIZE (1L << 4)
#define VISIONX_HINT_P_MAX_SIZE (1L << 5)
#define VISIONX_HINT_P_RESIZE_INC (1L << 6)
#define VISIONX_HINT_P_BASE_SIZE (1L << 8)
#define VISIONX_MAX_TRACKED_WINDOWS 256
#define VISIONX_DAMAGE_PADDING 2
#define VISIONX_DAMAGE_REGION_LIMIT 64

#ifndef VISIONX_ENABLE_RENDER_TRACE
#ifdef DEBUG
#define VISIONX_ENABLE_RENDER_TRACE 1
#else
#define VISIONX_ENABLE_RENDER_TRACE 0
#endif
#endif

#if VISIONX_ENABLE_RENDER_TRACE
#define VISIONX_SNAPSHOT_TRACE_LIMIT 800
#define VISIONX_COPY_TRACE_LIMIT 800
#define VISIONX_TRACK_TRACE_LIMIT 256
#define VISIONX_ZERO_COPY_TRACE_LIMIT 128
#else
#define VISIONX_SNAPSHOT_TRACE_LIMIT 0
#define VISIONX_COPY_TRACE_LIMIT 0
#define VISIONX_TRACK_TRACE_LIMIT 0
#define VISIONX_ZERO_COPY_TRACE_LIMIT 0
#endif

extern void visionx_glx_refresh_window_presentation(WindowPtr presentation);

typedef struct VisionXScreenInfo VisionXScreenInfo;

typedef struct {
    XID window;
    visionx_rect_t rect;
    PixmapPtr pixmap;
    uint8_t *snapshot;
    uint32_t snapshotWidth;
    uint32_t snapshotHeight;
    uint32_t snapshotBytesPerRow;
    Bool snapshotValid;
    Bool damageRegistered;
    int pixmapX;
    int pixmapY;
    Bool mapped;
} VisionXTrackedWindow;

typedef struct {
    VisionXScreenInfo *info;
    XID window;
} VisionXWindowDamage;

typedef struct {
    uint32_t hash;
    uint32_t samples;
    uint32_t nonzero;
} VisionXPixelSample;

struct VisionXScreenInfo {
    int width;
    int height;
    int depth;
    int bitsPerPixel;
    int paddedBytesWidth;
    int paddedWidth;
    char *framebuffer;
    visionx_ddx_screen_t *bridgeScreen;
    CloseScreenProcPtr closeScreen;
    CreateWindowProcPtr createWindow;
    DestroyWindowProcPtr destroyWindow;
    RealizeWindowProcPtr realizeWindow;
    UnrealizeWindowProcPtr unrealizeWindow;
    PositionWindowProcPtr positionWindow;
    pthread_mutex_t lock;
    VisionXTrackedWindow trackedWindows[VISIONX_MAX_TRACKED_WINDOWS];
    size_t trackedWindowCount;
    Bool propertyCallbackRegistered;
    char title[512];
    char wmInstance[256];
    char wmClass[256];
};

static VisionXScreenInfo visionxScreen = {
    .width = VISIONX_DEFAULT_WIDTH,
    .height = VISIONX_DEFAULT_HEIGHT,
    .depth = VISIONX_DEFAULT_DEPTH,
    .lock = PTHREAD_MUTEX_INITIALIZER,
};

#ifdef __APPLE__
void DarwinHandleGUI(int argc, char *argv[]);
#endif

#ifdef VISIONX_GLX_PROVIDER
void VisionXGLXRegisterExtension(void);
#endif

static Bool visionxPixmapDepths[33];
static uint32_t visionxSnapshotTraceCount;
static uint32_t visionxCopyTraceCount;
static uint32_t visionxTrackTraceCount;
static uint32_t visionxZeroCopyTraceCount;

static VisionXScreenInfo *visionxScreenInfo(ScreenPtr pScreen);
static Bool visionxReserveTraceSlot(uint32_t *counter, uint32_t limit);

static void visionxLog(const char *format, ...) _X_ATTRIBUTE_PRINTF(1, 2);

static void
visionxLog(const char *format, ...)
{
    char message[2048];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    visionx_ddx_log_message(message);
}

static int
visionxBitsPerPixel(int depth)
{
    if (depth == 1)
        return 1;
    if (depth <= 8)
        return 8;
    if (depth <= 16)
        return 16;
    return 32;
}

static visionx_rect_t
visionxWindowRect(WindowPtr pWin)
{
    visionx_rect_t rect;
    rect.x = pWin->drawable.x;
    rect.y = pWin->drawable.y;
    rect.width = pWin->drawable.width;
    rect.height = pWin->drawable.height;
    return rect;
}

static visionx_window_metadata_t
visionxWindowMetadata(WindowPtr pWin)
{
    VisionXScreenInfo *info = visionxScreenInfo(pWin->drawable.pScreen);
    visionx_window_metadata_t metadata;
    memset(&metadata, 0, sizeof(metadata));
    metadata.override_redirect = pWin->overrideRedirect ? 1 : 0;

    info->title[0] = '\0';
    info->wmInstance[0] = '\0';
    info->wmClass[0] = '\0';
    metadata.title = info->title;
    metadata.wm_instance = info->wmInstance;
    metadata.wm_class = info->wmClass;

    PropertyPtr prop;
    Atom utf8String = MakeAtom("UTF8_STRING", 11, TRUE);
    Atom netWmName = MakeAtom("_NET_WM_NAME", 12, TRUE);

    for (prop = wUserProps(pWin); prop != NULL; prop = prop->next) {
        if ((prop->propertyName == netWmName || prop->propertyName == XA_WM_NAME) &&
            (prop->type == XA_STRING || prop->type == utf8String) &&
            prop->format == 8 &&
            prop->data != NULL) {
            size_t len = prop->size < sizeof(info->title) - 1 ? prop->size : sizeof(info->title) - 1;
            memcpy(info->title, prop->data, len);
            info->title[len] = '\0';
            if (prop->propertyName == netWmName)
                break;
        }
    }

    for (prop = wUserProps(pWin); prop != NULL; prop = prop->next) {
        if (prop->propertyName == XA_WM_CLASS &&
            prop->type == XA_STRING &&
            prop->format == 8 &&
            prop->data != NULL &&
            prop->size > 0) {
            const char *data = (const char *)prop->data;
            size_t total = prop->size;
            size_t instanceLen = strnlen(data, total);
            size_t copiedInstance = instanceLen < sizeof(info->wmInstance) - 1 ? instanceLen : sizeof(info->wmInstance) - 1;
            memcpy(info->wmInstance, data, copiedInstance);
            info->wmInstance[copiedInstance] = '\0';

            if (instanceLen + 1 < total) {
                const char *className = data + instanceLen + 1;
                size_t classLen = strnlen(className, total - instanceLen - 1);
                size_t copiedClass = classLen < sizeof(info->wmClass) - 1 ? classLen : sizeof(info->wmClass) - 1;
                memcpy(info->wmClass, className, copiedClass);
                info->wmClass[copiedClass] = '\0';
            }
        }
        else if (prop->propertyName == XA_WM_TRANSIENT_FOR &&
                 prop->format == 32 &&
                 prop->data != NULL &&
                 prop->size >= 1) {
            metadata.transient_for = ((const uint32_t *)prop->data)[0];
            metadata.has_transient_for = 1;
        }
        else if (prop->propertyName == XA_WM_NORMAL_HINTS &&
                 prop->format == 32 &&
                 prop->data != NULL &&
                 prop->size >= 1) {
            const int32_t *hints = (const int32_t *)prop->data;
            int32_t flags = hints[0];

            if ((flags & VISIONX_HINT_P_MIN_SIZE) != 0 && prop->size >= 7) {
                metadata.min_width = hints[5];
                metadata.min_height = hints[6];
                metadata.has_min_size = 1;
            }
            if ((flags & VISIONX_HINT_P_MAX_SIZE) != 0 && prop->size >= 9) {
                metadata.max_width = hints[7];
                metadata.max_height = hints[8];
                metadata.has_max_size = 1;
            }
            if ((flags & VISIONX_HINT_P_RESIZE_INC) != 0 && prop->size >= 11) {
                metadata.width_increment = hints[9];
                metadata.height_increment = hints[10];
                metadata.has_resize_increment = 1;
            }
            if ((flags & VISIONX_HINT_P_BASE_SIZE) != 0 && prop->size >= 17) {
                metadata.base_width = hints[15];
                metadata.base_height = hints[16];
                metadata.has_base_size = 1;
            }
        }
    }

    Atom wmProtocols = MakeAtom("WM_PROTOCOLS", 12, TRUE);
    Atom wmDeleteWindow = MakeAtom("WM_DELETE_WINDOW", 16, TRUE);
    for (prop = wUserProps(pWin); prop != NULL; prop = prop->next) {
        if (prop->propertyName == wmProtocols &&
            prop->type == XA_ATOM &&
            prop->format == 32 &&
            prop->data != NULL) {
            const uint32_t *protocols = (const uint32_t *)prop->data;
            for (uint32_t i = 0; i < prop->size; i++) {
                if (protocols[i] == wmDeleteWindow) {
                    metadata.accepts_delete_window = 1;
                    break;
                }
            }
        }
    }

    return metadata;
}

static Bool
visionxIsTopLevel(WindowPtr pWin)
{
    return pWin != NULL &&
           pWin->parent != NULL &&
           pWin->drawable.pScreen != NULL &&
           pWin->parent == pWin->drawable.pScreen->root;
}

static VisionXScreenInfo *
visionxScreenInfo(ScreenPtr pScreen)
{
    (void) pScreen;
    return &visionxScreen;
}

static WindowPtr
visionxTopLevelForWindow(WindowPtr pWin)
{
    WindowPtr current = pWin;

    while (current != NULL &&
           current->parent != NULL &&
           current->parent->parent != NULL) {
        current = current->parent;
    }

    return current;
}

#ifdef COMPOSITE
static void
visionxRequestTopLevelRedirect(WindowPtr pWin)
{
    ScreenPtr pScreen;
    int status;

    if (pWin == NULL || !visionxIsTopLevel(pWin) || pWin->drawable.class == InputOnly)
        return;

    pScreen = pWin->drawable.pScreen;
    if (pScreen == NULL || GetCompScreen(pScreen) == NULL || CompositeClientWindowType == 0)
        return;

    if (GetCompWindow(pWin) != NULL)
        return;

    status = compRedirectWindow(serverClient, pWin, CompositeRedirectAutomatic);
    if (status == Success) {
        visionxLog("registered automatic composite redirect window=%u",
                   (unsigned) pWin->drawable.id);
    }
    else {
        visionxLog("automatic composite redirect failed window=%u status=%d",
                   (unsigned) pWin->drawable.id,
                   status);
    }
}

#endif

static PixmapPtr
visionxCreateWindowPixmap(ScreenPtr pScreen, WindowPtr pWin)
{
    PixmapPtr pixmap = NULL;

    if (pScreen == NULL || pWin == NULL || pScreen->CreatePixmap == NULL)
        return NULL;

    pixmap = (*pScreen->CreatePixmap)(
        pScreen,
        pWin->drawable.width,
        pWin->drawable.height,
        pWin->drawable.depth,
        CREATE_PIXMAP_USAGE_BACKING_PIXMAP
    );
    if (pixmap == NULL) {
        visionxLog("window pixmap allocation failed window=%u size=%dx%d",
                   (unsigned) pWin->drawable.id,
                   pWin->drawable.width,
                   pWin->drawable.height);
        return NULL;
    }

#ifdef COMPOSITE
    pixmap->screen_x = pWin->drawable.x;
    pixmap->screen_y = pWin->drawable.y;
#endif

    memset(pixmap->devPrivate.ptr, 0, (size_t) pixmap->devKind * (size_t) pixmap->drawable.height);
    visionxLog("window pixmap allocated window=%u size=%dx%d depth=%d bpp=%d",
               (unsigned) pWin->drawable.id,
               pixmap->drawable.width,
               pixmap->drawable.height,
               pixmap->drawable.depth,
               pixmap->drawable.bitsPerPixel);
    return pixmap;
}

static Bool
visionxIsPrivateWindowPixmap(ScreenPtr pScreen, PixmapPtr pixmap)
{
    return pScreen != NULL &&
           pixmap != NULL &&
           pixmap->devPrivate.ptr != NULL &&
           pixmap != fbGetScreenPixmap(pScreen);
}

static int
visionxPixmapContentOffsetX(WindowPtr pWin, PixmapPtr pixmap)
{
#ifdef COMPOSITE
    if (pWin != NULL && pixmap != NULL)
        return pWin->drawable.x - pixmap->screen_x;
#endif
    (void) pWin;
    (void) pixmap;
    return 0;
}

static int
visionxPixmapContentOffsetY(WindowPtr pWin, PixmapPtr pixmap)
{
#ifdef COMPOSITE
    if (pWin != NULL && pixmap != NULL)
        return pWin->drawable.y - pixmap->screen_y;
#endif
    (void) pWin;
    (void) pixmap;
    return 0;
}

static Bool
visionxPixmapCoversWindow(WindowPtr pWin, PixmapPtr pixmap)
{
    int offsetX;
    int offsetY;

    if (pWin == NULL || pixmap == NULL || pWin->drawable.pScreen == NULL)
        return FALSE;
    if (!visionxIsPrivateWindowPixmap(pWin->drawable.pScreen, pixmap))
        return FALSE;
    if (pixmap->drawable.depth != pWin->drawable.depth)
        return FALSE;

    offsetX = visionxPixmapContentOffsetX(pWin, pixmap);
    offsetY = visionxPixmapContentOffsetY(pWin, pixmap);
    if (offsetX < 0 || offsetY < 0)
        return FALSE;

    return offsetX + (int) pWin->drawable.width <= pixmap->drawable.width &&
           offsetY + (int) pWin->drawable.height <= pixmap->drawable.height;
}

static int
visionxSetSubtreePixmapVisitor(WindowPtr pWin, void *data)
{
    PixmapPtr pixmap = (PixmapPtr) data;
    ScreenPtr pScreen = pWin->drawable.pScreen;

    (*pScreen->SetWindowPixmap) (pWin, pixmap);
    SetWinSize(pWin);
    SetBorderSize(pWin);
    return WT_WALKCHILDREN;
}

static void
visionxSetSubtreePixmap(WindowPtr pWin, PixmapPtr pixmap)
{
    if (pWin == NULL || pixmap == NULL)
        return;

    TraverseTree(pWin, visionxSetSubtreePixmapVisitor, pixmap);
}

static PixmapPtr
visionxEnsureTopLevelPixmap(ScreenPtr pScreen, WindowPtr pWin)
{
    PixmapPtr pixmap;
    PixmapPtr oldPixmap;

    if (pScreen == NULL || pWin == NULL || !visionxIsTopLevel(pWin))
        return NULL;

    pixmap = (*pScreen->GetWindowPixmap) (pWin);
    if (visionxPixmapCoversWindow(pWin, pixmap)) {
#ifdef COMPOSITE
        if (pWin->redirectDraw == RedirectDrawNone) {
            pixmap->screen_x = pWin->drawable.x;
            pixmap->screen_y = pWin->drawable.y;
        }
#endif
        return pixmap;
    }

    oldPixmap = pixmap;
    pixmap = visionxCreateWindowPixmap(pScreen, pWin);
    if (pixmap == NULL)
        return visionxIsPrivateWindowPixmap(pScreen, oldPixmap) ? oldPixmap : NULL;

    visionxSetSubtreePixmap(pWin, pixmap);

    if (visionxIsPrivateWindowPixmap(pScreen, oldPixmap))
        (*pScreen->DestroyPixmap) (oldPixmap);

    return pixmap;
}

static void
visionxRetainTrackedPixmap(PixmapPtr pixmap)
{
    if (pixmap == NULL || pixmap->drawable.pScreen == NULL)
        return;
    if (!visionxIsPrivateWindowPixmap(pixmap->drawable.pScreen, pixmap))
        return;

    pixmap->refcnt++;
}

static void
visionxReleaseTrackedPixmap(PixmapPtr pixmap)
{
    ScreenPtr pScreen;

    if (pixmap == NULL || pixmap->drawable.pScreen == NULL)
        return;

    pScreen = pixmap->drawable.pScreen;
    if (!visionxIsPrivateWindowPixmap(pScreen, pixmap))
        return;

    (*pScreen->DestroyPixmap) (pixmap);
}

static void
visionxFreeTrackedSnapshot(VisionXTrackedWindow *tracked)
{
    if (tracked == NULL)
        return;

    free(tracked->snapshot);
    tracked->snapshot = NULL;
    tracked->snapshotWidth = 0;
    tracked->snapshotHeight = 0;
    tracked->snapshotBytesPerRow = 0;
    tracked->snapshotValid = FALSE;
}

static Bool
visionxCanSnapshotPixmap(PixmapPtr pixmap)
{
    return pixmap != NULL &&
           pixmap->devPrivate.ptr != NULL &&
           pixmap->drawable.pScreen != NULL &&
           pixmap != fbGetScreenPixmap(pixmap->drawable.pScreen) &&
           pixmap->drawable.bitsPerPixel == 32 &&
           pixmap->drawable.width > 0 &&
           pixmap->drawable.height > 0;
}

static Bool
visionxShouldTraceTrackedWindow(const VisionXTrackedWindow *tracked)
{
    return tracked != NULL &&
           tracked->mapped &&
           tracked->rect.width >= 256 &&
           tracked->rect.height >= 200;
}

static Bool
visionxReserveTraceSlot(uint32_t *counter, uint32_t limit)
{
    if (counter == NULL || *counter >= limit)
        return FALSE;

    (*counter)++;
    return TRUE;
}

static VisionXPixelSample
visionxSampleBGRARegion(const uint8_t *data,
                        uint32_t dataWidth,
                        uint32_t dataHeight,
                        uint32_t bytesPerRow,
                        int32_t x,
                        int32_t y,
                        uint32_t width,
                        uint32_t height)
{
    VisionXPixelSample sample = {0, 0, 0};
    uint32_t x1;
    uint32_t y1;
    uint32_t stepX;
    uint32_t stepY;
    uint32_t hash = 2166136261u;

    if (data == NULL ||
        dataWidth == 0 ||
        dataHeight == 0 ||
        dataWidth > UINT32_MAX / 4 ||
        bytesPerRow < dataWidth * 4 ||
        width == 0 ||
        height == 0 ||
        x < 0 ||
        y < 0)
        return sample;

    x1 = (uint32_t) x;
    y1 = (uint32_t) y;
    if (x1 >= dataWidth || y1 >= dataHeight)
        return sample;

    if (width > dataWidth - x1)
        width = dataWidth - x1;
    if (height > dataHeight - y1)
        height = dataHeight - y1;
    if (width == 0 || height == 0)
        return sample;

    stepX = width > 16 ? width / 16 : 1;
    stepY = height > 16 ? height / 16 : 1;

    for (uint32_t row = 0; row < height; row += stepY) {
        const uint8_t *line = data + ((size_t) (y1 + row) * (size_t) bytesPerRow);
        for (uint32_t column = 0; column < width; column += stepX) {
            const uint8_t *pixel = line + ((size_t) (x1 + column) * 4);
            uint32_t value =
                ((uint32_t) pixel[0]) |
                ((uint32_t) pixel[1] << 8) |
                ((uint32_t) pixel[2] << 16) |
                ((uint32_t) pixel[3] << 24);

            hash ^= value;
            hash *= 16777619u;
            sample.samples++;
            if ((pixel[0] | pixel[1] | pixel[2]) != 0)
                sample.nonzero++;
        }
    }

    hash ^= sample.samples;
    hash *= 16777619u;
    hash ^= sample.nonzero;
    hash *= 16777619u;
    sample.hash = hash;
    return sample;
}

static Bool
visionxEnsureTrackedSnapshotLocked(VisionXTrackedWindow *tracked)
{
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    size_t requiredLength;
    uint8_t *snapshot;

    if (tracked == NULL ||
        tracked->rect.width <= 0 ||
        tracked->rect.height <= 0) {
        visionxFreeTrackedSnapshot(tracked);
        return FALSE;
    }

    width = (uint32_t) tracked->rect.width;
    height = (uint32_t) tracked->rect.height;
    if (width > UINT32_MAX / 4)
        return FALSE;
    bytesPerRow = width * 4;
    if ((size_t) height > SIZE_MAX / (size_t) bytesPerRow)
        return FALSE;
    requiredLength = (size_t) bytesPerRow * (size_t) height;

    if (tracked->snapshot != NULL &&
        tracked->snapshotWidth == width &&
        tracked->snapshotHeight == height &&
        tracked->snapshotBytesPerRow == bytesPerRow)
        return TRUE;

    snapshot = calloc(1, requiredLength);
    if (snapshot == NULL) {
        visionxFreeTrackedSnapshot(tracked);
        visionxLog("window snapshot allocation failed window=%u size=%ux%u bytes=%zu",
                   (unsigned) tracked->window,
                   width,
                   height,
                   requiredLength);
        return FALSE;
    }

    visionxFreeTrackedSnapshot(tracked);
    tracked->snapshot = snapshot;
    tracked->snapshotWidth = width;
    tracked->snapshotHeight = height;
    tracked->snapshotBytesPerRow = bytesPerRow;
    return TRUE;
}

static Bool
visionxClipTrackedRegionLocked(VisionXTrackedWindow *tracked,
                               const visionx_rect_t *requestedRegion,
                               int32_t *x1,
                               int32_t *y1,
                               int32_t *x2,
                               int32_t *y2)
{
    int64_t requestedX2;
    int64_t requestedY2;

    if (tracked == NULL ||
        tracked->rect.width <= 0 ||
        tracked->rect.height <= 0 ||
        x1 == NULL ||
        y1 == NULL ||
        x2 == NULL ||
        y2 == NULL)
        return FALSE;

    if (requestedRegion == NULL) {
        *x1 = 0;
        *y1 = 0;
        *x2 = tracked->rect.width;
        *y2 = tracked->rect.height;
        return TRUE;
    }

    if (requestedRegion->width <= 0 || requestedRegion->height <= 0)
        return FALSE;

    requestedX2 = (int64_t) requestedRegion->x + (int64_t) requestedRegion->width;
    requestedY2 = (int64_t) requestedRegion->y + (int64_t) requestedRegion->height;
    *x1 = requestedRegion->x < 0 ? 0 : requestedRegion->x;
    *y1 = requestedRegion->y < 0 ? 0 : requestedRegion->y;
    *x2 = requestedX2 > tracked->rect.width ? tracked->rect.width : (int32_t) requestedX2;
    *y2 = requestedY2 > tracked->rect.height ? tracked->rect.height : (int32_t) requestedY2;

    return *x2 > *x1 && *y2 > *y1;
}

static Bool
visionxRefreshTrackedSnapshotLocked(VisionXTrackedWindow *tracked, const visionx_rect_t *requestedRegion)
{
    int32_t x1;
    int32_t y1;
    int32_t x2;
    int32_t y2;
    uint32_t width;
    uint32_t height;
    int sourceX;
    int sourceY;
    uint32_t destOffsetX = 0;
    uint32_t destOffsetY = 0;
    uint32_t copyWidth = 0;
    uint32_t copyHeight = 0;
    const uint8_t *pixmapData;
    Bool hadRequestedRegion = requestedRegion != NULL;
    visionx_rect_t originalRegion = {0, 0, 0, 0};
    Bool wasSnapshotValid = tracked != NULL ? tracked->snapshotValid : FALSE;

    if (hadRequestedRegion)
        originalRegion = *requestedRegion;

    if (tracked == NULL || !tracked->mapped || !visionxCanSnapshotPixmap(tracked->pixmap)) {
        if (tracked != NULL &&
            visionxShouldTraceTrackedWindow(tracked) &&
            visionxReserveTraceSlot(&visionxSnapshotTraceCount, VISIONX_SNAPSHOT_TRACE_LIMIT)) {
            PixmapPtr pixmap = tracked->pixmap;
            visionxLog("snapshot unavailable window=%u mapped=%d pixmap=%p ptr=%p pixmap=%dx%d bpp=%d kind=%d",
                       (unsigned) tracked->window,
                       tracked->mapped ? 1 : 0,
                       (void *) pixmap,
                       pixmap != NULL ? pixmap->devPrivate.ptr : NULL,
                       pixmap != NULL ? pixmap->drawable.width : 0,
                       pixmap != NULL ? pixmap->drawable.height : 0,
                       pixmap != NULL ? pixmap->drawable.bitsPerPixel : 0,
                       pixmap != NULL ? pixmap->devKind : 0);
        }
        visionxFreeTrackedSnapshot(tracked);
        return FALSE;
    }

    if (!visionxEnsureTrackedSnapshotLocked(tracked)) {
        if (visionxShouldTraceTrackedWindow(tracked) &&
            visionxReserveTraceSlot(&visionxSnapshotTraceCount, VISIONX_SNAPSHOT_TRACE_LIMIT)) {
            visionxLog("snapshot ensure failed window=%u rect=%dx%d+%d+%d",
                       (unsigned) tracked->window,
                       tracked->rect.width,
                       tracked->rect.height,
                       tracked->rect.x,
                       tracked->rect.y);
        }
        return FALSE;
    }

    if (!tracked->snapshotValid)
        requestedRegion = NULL;

    if (!visionxClipTrackedRegionLocked(tracked, requestedRegion, &x1, &y1, &x2, &y2)) {
        if (visionxShouldTraceTrackedWindow(tracked) &&
            visionxReserveTraceSlot(&visionxSnapshotTraceCount, VISIONX_SNAPSHOT_TRACE_LIMIT)) {
            visionxLog("snapshot clip failed window=%u request=%dx%d+%d+%d hadRequest=%d validBefore=%d rect=%dx%d",
                       (unsigned) tracked->window,
                       originalRegion.width,
                       originalRegion.height,
                       originalRegion.x,
                       originalRegion.y,
                       hadRequestedRegion ? 1 : 0,
                       wasSnapshotValid ? 1 : 0,
                       tracked->rect.width,
                       tracked->rect.height);
        }
        return FALSE;
    }

    width = (uint32_t) (x2 - x1);
    height = (uint32_t) (y2 - y1);

    for (uint32_t row = 0; row < height; row++) {
        uint8_t *dst = tracked->snapshot +
            ((size_t) (y1 + (int32_t) row) * (size_t) tracked->snapshotBytesPerRow) +
            ((size_t) x1 * 4);
        memset(dst, 0, (size_t) width * 4);
    }

    sourceX = tracked->pixmapX + x1;
    sourceY = tracked->pixmapY + y1;
    if (sourceX < 0) {
        destOffsetX = (uint32_t) -sourceX;
        sourceX = 0;
    }
    if (sourceY < 0) {
        destOffsetY = (uint32_t) -sourceY;
        sourceY = 0;
    }

    if (destOffsetX < width &&
        destOffsetY < height &&
        sourceX < tracked->pixmap->drawable.width &&
        sourceY < tracked->pixmap->drawable.height) {
        copyWidth = (uint32_t) (tracked->pixmap->drawable.width - sourceX);
        copyHeight = (uint32_t) (tracked->pixmap->drawable.height - sourceY);
        if (copyWidth > width - destOffsetX)
            copyWidth = width - destOffsetX;
        if (copyHeight > height - destOffsetY)
            copyHeight = height - destOffsetY;
    }

    pixmapData = (const uint8_t *) tracked->pixmap->devPrivate.ptr;
    for (uint32_t row = 0; row < copyHeight; row++) {
        uint8_t *dst = tracked->snapshot +
            ((size_t) (y1 + (int32_t) destOffsetY + (int32_t) row) * (size_t) tracked->snapshotBytesPerRow) +
            ((size_t) (x1 + (int32_t) destOffsetX) * 4);
        const uint8_t *src = pixmapData +
            ((size_t) (sourceY + (int) row) * (size_t) tracked->pixmap->devKind) +
            ((size_t) sourceX * 4);

        for (uint32_t column = 0; column < copyWidth; column++) {
            dst[(size_t) column * 4 + 0] = src[(size_t) column * 4 + 0];
            dst[(size_t) column * 4 + 1] = src[(size_t) column * 4 + 1];
            dst[(size_t) column * 4 + 2] = src[(size_t) column * 4 + 2];
            dst[(size_t) column * 4 + 3] = 0xff;
        }
    }

    if (visionxShouldTraceTrackedWindow(tracked)) {
        uint32_t *traceCounter = copyWidth == 0 || copyHeight == 0 ? &visionxZeroCopyTraceCount : &visionxSnapshotTraceCount;
        uint32_t traceLimit = copyWidth == 0 || copyHeight == 0 ? VISIONX_ZERO_COPY_TRACE_LIMIT : VISIONX_SNAPSHOT_TRACE_LIMIT;
        if (visionxReserveTraceSlot(traceCounter, traceLimit)) {
            VisionXPixelSample sourceSample = visionxSampleBGRARegion(
                pixmapData,
                (uint32_t) tracked->pixmap->drawable.width,
                (uint32_t) tracked->pixmap->drawable.height,
                (uint32_t) tracked->pixmap->devKind,
                sourceX,
                sourceY,
                copyWidth,
                copyHeight
            );
            VisionXPixelSample snapshotSample = visionxSampleBGRARegion(
                tracked->snapshot,
                tracked->snapshotWidth,
                tracked->snapshotHeight,
                tracked->snapshotBytesPerRow,
                x1,
                y1,
                width,
                height
            );
            visionxLog("snapshot refresh window=%u request=%dx%d+%d+%d hadRequest=%d full=%d validBefore=%d clip=%ux%u+%d+%d pixmap=%dx%d kind=%d bpp=%d offset=%d,%d source=%d,%d copy=%ux%u destOffset=%u,%u sourceHash=%08x sourceNZ=%u/%u snapHash=%08x snapNZ=%u/%u",
                       (unsigned) tracked->window,
                       originalRegion.width,
                       originalRegion.height,
                       originalRegion.x,
                       originalRegion.y,
                       hadRequestedRegion ? 1 : 0,
                       requestedRegion == NULL ? 1 : 0,
                       wasSnapshotValid ? 1 : 0,
                       width,
                       height,
                       x1,
                       y1,
                       tracked->pixmap->drawable.width,
                       tracked->pixmap->drawable.height,
                       tracked->pixmap->devKind,
                       tracked->pixmap->drawable.bitsPerPixel,
                       tracked->pixmapX,
                       tracked->pixmapY,
                       sourceX,
                       sourceY,
                       copyWidth,
                       copyHeight,
                       destOffsetX,
                       destOffsetY,
                       sourceSample.hash,
                       sourceSample.nonzero,
                       sourceSample.samples,
                       snapshotSample.hash,
                       snapshotSample.nonzero,
                       snapshotSample.samples);
        }
    }

    tracked->snapshotValid = TRUE;
    return TRUE;
}

static visionx_rect_t
visionxPadDamageRect(visionx_rect_t rect)
{
    int32_t padding = VISIONX_DAMAGE_PADDING;
    int64_t x1 = (int64_t) rect.x - padding;
    int64_t y1 = (int64_t) rect.y - padding;
    int64_t x2 = (int64_t) rect.x + rect.width + padding;
    int64_t y2 = (int64_t) rect.y + rect.height + padding;

    if (x1 < INT32_MIN)
        x1 = INT32_MIN;
    if (y1 < INT32_MIN)
        y1 = INT32_MIN;
    if (x2 > INT32_MAX)
        x2 = INT32_MAX;
    if (y2 > INT32_MAX)
        y2 = INT32_MAX;

    rect.x = (int32_t) x1;
    rect.y = (int32_t) y1;
    rect.width = (int32_t) (x2 - x1);
    rect.height = (int32_t) (y2 - y1);
    return rect;
}

static void
visionxReportDamage(DamagePtr pDamage, RegionPtr pRegion, void *closure)
{
    VisionXWindowDamage *windowDamage = (VisionXWindowDamage *) closure;
    VisionXScreenInfo *info;
    visionx_rect_t rects[VISIONX_DAMAGE_REGION_LIMIT];
    size_t rectCount = 0;
    int regionCount;
    BoxPtr boxes;

    (void) pDamage;

    if (windowDamage == NULL ||
        windowDamage->info == NULL ||
        windowDamage->info->bridgeScreen == NULL ||
        pRegion == NULL ||
        !RegionNotEmpty(pRegion))
        return;

    regionCount = RegionNumRects(pRegion);
    boxes = RegionRects(pRegion);
    if (regionCount > 0 && regionCount <= VISIONX_DAMAGE_REGION_LIMIT && boxes != NULL) {
        for (int i = 0; i < regionCount; i++) {
            visionx_rect_t rect;
            rect.x = boxes[i].x1;
            rect.y = boxes[i].y1;
            rect.width = boxes[i].x2 - boxes[i].x1;
            rect.height = boxes[i].y2 - boxes[i].y1;
            if (rect.width <= 0 || rect.height <= 0)
                continue;
            rects[rectCount++] = visionxPadDamageRect(rect);
        }
    }

    if (rectCount == 0) {
        BoxPtr extents = RegionExtents(pRegion);
        visionx_rect_t rect;
        rect.x = extents->x1;
        rect.y = extents->y1;
        rect.width = extents->x2 - extents->x1;
        rect.height = extents->y2 - extents->y1;
        if (rect.width <= 0 || rect.height <= 0)
            return;
        rects[rectCount++] = visionxPadDamageRect(rect);
    }

    info = windowDamage->info;
    visionx_ddx_mark_damage_regions(info->bridgeScreen, windowDamage->window, rects, rectCount, 0);
}

static void
visionxDestroyDamage(DamagePtr pDamage, void *closure)
{
    (void) pDamage;
    free(closure);
}

static Bool
visionxCreateDamage(VisionXScreenInfo *info, WindowPtr pWin)
{
    VisionXWindowDamage *windowDamage;
    DamagePtr damage;

    if (info == NULL ||
        pWin == NULL ||
        pWin->drawable.pScreen == NULL ||
        pWin->drawable.class == InputOnly)
        return FALSE;

    windowDamage = calloc(1, sizeof(*windowDamage));
    if (windowDamage == NULL)
        return FALSE;

    windowDamage->info = info;
    windowDamage->window = pWin->drawable.id;
    damage = DamageCreate(
        visionxReportDamage,
        visionxDestroyDamage,
        DamageReportRawRegion,
        TRUE,
        pWin->drawable.pScreen,
        windowDamage
    );
    if (damage == NULL) {
        free(windowDamage);
        return FALSE;
    }

    DamageSetReportAfterOp(damage, TRUE);
    DamageRegister(&pWin->drawable, damage);
    visionxLog("damage registered window=%u", (unsigned) pWin->drawable.id);
    return TRUE;
}

static Bool
visionxHasTrackedDamage(VisionXScreenInfo *info, XID window)
{
    Bool hasDamage = FALSE;

    if (info == NULL)
        return FALSE;

    pthread_mutex_lock(&info->lock);
    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window) {
            hasDamage = info->trackedWindows[i].damageRegistered;
            break;
        }
    }
    pthread_mutex_unlock(&info->lock);
    return hasDamage;
}

static void
visionxTrackWindow(VisionXScreenInfo *info, XID window, visionx_rect_t rect, PixmapPtr pixmap, Bool damageRegistered, int pixmapX, int pixmapY, Bool mapped)
{
    PixmapPtr oldPixmap = NULL;
    Bool needsSnapshotRefresh = FALSE;

    if (info == NULL)
        return;

    pthread_mutex_lock(&info->lock);
    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window) {
            VisionXTrackedWindow *tracked = &info->trackedWindows[i];
            if (tracked->rect.width != rect.width || tracked->rect.height != rect.height)
                needsSnapshotRefresh = TRUE;
            tracked->rect = rect;
            if (pixmap != info->trackedWindows[i].pixmap) {
                visionxRetainTrackedPixmap(pixmap);
                oldPixmap = tracked->pixmap;
                tracked->pixmap = pixmap;
                needsSnapshotRefresh = TRUE;
            }
            if (damageRegistered)
                tracked->damageRegistered = TRUE;
            if (tracked->pixmapX != (pixmap != NULL ? pixmapX : 0) ||
                tracked->pixmapY != (pixmap != NULL ? pixmapY : 0))
                needsSnapshotRefresh = TRUE;
            tracked->pixmapX = pixmap != NULL ? pixmapX : 0;
            tracked->pixmapY = pixmap != NULL ? pixmapY : 0;
            tracked->mapped = mapped;
            if (visionxShouldTraceTrackedWindow(tracked) &&
                visionxReserveTraceSlot(&visionxTrackTraceCount, VISIONX_TRACK_TRACE_LIMIT)) {
                visionxLog("track update window=%u rect=%dx%d+%d+%d mapped=%d pixmap=%p pixmap=%dx%d bpp=%d kind=%d offset=%d,%d damage=%d refresh=%d",
                           (unsigned) tracked->window,
                           tracked->rect.width,
                           tracked->rect.height,
                           tracked->rect.x,
                           tracked->rect.y,
                           tracked->mapped ? 1 : 0,
                           (void *) tracked->pixmap,
                           tracked->pixmap != NULL ? tracked->pixmap->drawable.width : 0,
                           tracked->pixmap != NULL ? tracked->pixmap->drawable.height : 0,
                           tracked->pixmap != NULL ? tracked->pixmap->drawable.bitsPerPixel : 0,
                           tracked->pixmap != NULL ? tracked->pixmap->devKind : 0,
                           tracked->pixmapX,
                           tracked->pixmapY,
                           tracked->damageRegistered ? 1 : 0,
                           needsSnapshotRefresh || !tracked->snapshotValid ? 1 : 0);
            }
            if (!mapped || pixmap == NULL)
                visionxFreeTrackedSnapshot(tracked);
            else if (needsSnapshotRefresh)
                tracked->snapshotValid = FALSE;
            pthread_mutex_unlock(&info->lock);
            visionxReleaseTrackedPixmap(oldPixmap);
            return;
        }
    }

    if (info->trackedWindowCount < VISIONX_MAX_TRACKED_WINDOWS) {
        VisionXTrackedWindow *tracked = &info->trackedWindows[info->trackedWindowCount++];
        memset(tracked, 0, sizeof(*tracked));
        visionxRetainTrackedPixmap(pixmap);
        tracked->window = window;
        tracked->rect = rect;
        tracked->pixmap = pixmap;
        tracked->damageRegistered = damageRegistered;
        tracked->pixmapX = pixmap != NULL ? pixmapX : 0;
        tracked->pixmapY = pixmap != NULL ? pixmapY : 0;
        tracked->mapped = mapped;
        if (visionxShouldTraceTrackedWindow(tracked) &&
            visionxReserveTraceSlot(&visionxTrackTraceCount, VISIONX_TRACK_TRACE_LIMIT)) {
            visionxLog("track new window=%u rect=%dx%d+%d+%d mapped=%d pixmap=%p pixmap=%dx%d bpp=%d kind=%d offset=%d,%d damage=%d",
                       (unsigned) tracked->window,
                       tracked->rect.width,
                       tracked->rect.height,
                       tracked->rect.x,
                       tracked->rect.y,
                       tracked->mapped ? 1 : 0,
                       (void *) tracked->pixmap,
                       tracked->pixmap != NULL ? tracked->pixmap->drawable.width : 0,
                       tracked->pixmap != NULL ? tracked->pixmap->drawable.height : 0,
                       tracked->pixmap != NULL ? tracked->pixmap->drawable.bitsPerPixel : 0,
                       tracked->pixmap != NULL ? tracked->pixmap->devKind : 0,
                       tracked->pixmapX,
                       tracked->pixmapY,
                       tracked->damageRegistered ? 1 : 0);
        }
        if (mapped && pixmap != NULL)
            tracked->snapshotValid = FALSE;
    }
    else {
        visionxLog("tracked window table full; dropping window=%u", (unsigned) window);
    }
    pthread_mutex_unlock(&info->lock);
}

static void
visionxTrackWindowForWindow(VisionXScreenInfo *info, WindowPtr pWin, PixmapPtr pixmap, Bool mapped)
{
    int pixmapX = 0;
    int pixmapY = 0;
    Bool damageRegistered = FALSE;

    if (pWin == NULL)
        return;

    if (pixmap != NULL) {
        pixmapX = visionxPixmapContentOffsetX(pWin, pixmap);
        pixmapY = visionxPixmapContentOffsetY(pWin, pixmap);
    }

    if (mapped && !visionxHasTrackedDamage(info, pWin->drawable.id))
        damageRegistered = visionxCreateDamage(info, pWin);

    visionxTrackWindow(info, pWin->drawable.id, visionxWindowRect(pWin), pixmap, damageRegistered, pixmapX, pixmapY, mapped);
}

static void
visionxUntrackWindow(VisionXScreenInfo *info, XID window)
{
    PixmapPtr oldPixmap = NULL;

    if (info == NULL)
        return;

    pthread_mutex_lock(&info->lock);
    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window) {
            size_t lastIndex = info->trackedWindowCount - 1;
            oldPixmap = info->trackedWindows[i].pixmap;
            visionxFreeTrackedSnapshot(&info->trackedWindows[i]);
            if (i != lastIndex)
                info->trackedWindows[i] = info->trackedWindows[lastIndex];
            memset(&info->trackedWindows[lastIndex], 0, sizeof(info->trackedWindows[lastIndex]));
            info->trackedWindowCount--;
            break;
        }
    }
    pthread_mutex_unlock(&info->lock);
    visionxReleaseTrackedPixmap(oldPixmap);
}

static void
visionxReleaseAllTrackedWindows(VisionXScreenInfo *info)
{
    PixmapPtr pixmaps[VISIONX_MAX_TRACKED_WINDOWS];
    size_t pixmapCount = 0;

    if (info == NULL)
        return;

    pthread_mutex_lock(&info->lock);
    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].pixmap != NULL)
            pixmaps[pixmapCount++] = info->trackedWindows[i].pixmap;
        visionxFreeTrackedSnapshot(&info->trackedWindows[i]);
        memset(&info->trackedWindows[i], 0, sizeof(info->trackedWindows[i]));
    }
    info->trackedWindowCount = 0;
    pthread_mutex_unlock(&info->lock);

    for (size_t i = 0; i < pixmapCount; i++)
        visionxReleaseTrackedPixmap(pixmaps[i]);
}

int
visionx_ddx_copy_window_pixels(visionx_xid_t window,
                               uint8_t *destination,
                               size_t destination_length,
                               visionx_pixel_buffer_info_t *pixelInfo)
{
    VisionXScreenInfo *info = &visionxScreen;
    VisionXTrackedWindow *tracked = NULL;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    size_t requiredLength;

    if (pixelInfo == NULL)
        return 0;

    memset(pixelInfo, 0, sizeof(*pixelInfo));

    pthread_mutex_lock(&info->lock);

    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window && info->trackedWindows[i].mapped) {
            tracked = &info->trackedWindows[i];
            break;
        }
    }

    if (tracked == NULL ||
        tracked->rect.width <= 0 ||
        tracked->rect.height <= 0) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }

    width = (uint32_t) tracked->rect.width;
    height = (uint32_t) tracked->rect.height;
    if (width > UINT32_MAX / 4 ||
        (size_t) height > SIZE_MAX / ((size_t) width * 4)) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }
    bytesPerRow = width * 4;
    requiredLength = (size_t) bytesPerRow * (size_t) height;

    pixelInfo->width = width;
    pixelInfo->height = height;
    pixelInfo->bytes_per_row = bytesPerRow;

    if (destination == NULL) {
        pthread_mutex_unlock(&info->lock);
        return 1;
    }
    if (destination_length < requiredLength) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }
    if (!visionxRefreshTrackedSnapshotLocked(tracked, NULL) ||
        tracked->snapshot == NULL ||
        !tracked->snapshotValid ||
        tracked->snapshotWidth != width ||
        tracked->snapshotHeight != height ||
        tracked->snapshotBytesPerRow != bytesPerRow) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }

    memcpy(destination, tracked->snapshot, requiredLength);
    if (visionxShouldTraceTrackedWindow(tracked) &&
        visionxReserveTraceSlot(&visionxCopyTraceCount, VISIONX_COPY_TRACE_LIMIT)) {
        VisionXPixelSample sample = visionxSampleBGRARegion(
            destination,
            width,
            height,
            bytesPerRow,
            0,
            0,
            width,
            height
        );
        visionxLog("snapshot copy full window=%u size=%ux%u bytesPerRow=%u hash=%08x nz=%u/%u",
                   (unsigned) tracked->window,
                   width,
                   height,
                   bytesPerRow,
                   sample.hash,
                   sample.nonzero,
                   sample.samples);
    }
    pthread_mutex_unlock(&info->lock);
    return 1;
}

int
visionx_ddx_copy_window_pixel_region(visionx_xid_t window,
                                     visionx_rect_t requestedRegion,
                                     uint8_t *destination,
                                     size_t destination_length,
                                     visionx_pixel_region_info_t *regionInfo)
{
    VisionXScreenInfo *info = &visionxScreen;
    VisionXTrackedWindow *tracked = NULL;
    int32_t x1;
    int32_t y1;
    int32_t x2;
    int32_t y2;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t windowBytesPerRow;
    size_t requiredLength;

    if (regionInfo == NULL)
        return 0;

    memset(regionInfo, 0, sizeof(*regionInfo));

    if (requestedRegion.width <= 0 || requestedRegion.height <= 0)
        return 0;

    pthread_mutex_lock(&info->lock);

    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window && info->trackedWindows[i].mapped) {
            tracked = &info->trackedWindows[i];
            break;
        }
    }

    if (tracked == NULL ||
        !visionxClipTrackedRegionLocked(tracked, &requestedRegion, &x1, &y1, &x2, &y2)) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }

    regionInfo->window_width = (uint32_t) tracked->rect.width;
    regionInfo->window_height = (uint32_t) tracked->rect.height;

    width = (uint32_t) (x2 - x1);
    height = (uint32_t) (y2 - y1);
    if (width > UINT32_MAX / 4 ||
        (size_t) height > SIZE_MAX / ((size_t) width * 4) ||
        regionInfo->window_width > UINT32_MAX / 4) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }
    bytesPerRow = width * 4;
    windowBytesPerRow = regionInfo->window_width * 4;
    requiredLength = (size_t) bytesPerRow * (size_t) height;

    regionInfo->x = x1;
    regionInfo->y = y1;
    regionInfo->width = width;
    regionInfo->height = height;
    regionInfo->bytes_per_row = bytesPerRow;

    if (destination == NULL) {
        pthread_mutex_unlock(&info->lock);
        return 1;
    }
    if (destination_length < requiredLength) {
        pthread_mutex_unlock(&info->lock);
        return 0;
    }
    {
        visionx_rect_t clippedRegion;
        clippedRegion.x = x1;
        clippedRegion.y = y1;
        clippedRegion.width = (int32_t) width;
        clippedRegion.height = (int32_t) height;
        if (!visionxRefreshTrackedSnapshotLocked(tracked, &clippedRegion) ||
            tracked->snapshot == NULL ||
            !tracked->snapshotValid ||
            tracked->snapshotWidth != regionInfo->window_width ||
            tracked->snapshotHeight != regionInfo->window_height ||
            tracked->snapshotBytesPerRow != windowBytesPerRow) {
            pthread_mutex_unlock(&info->lock);
            return 0;
        }
    }

    for (uint32_t row = 0; row < height; row++) {
        const uint8_t *src = tracked->snapshot +
            ((size_t) (y1 + (int32_t) row) * (size_t) tracked->snapshotBytesPerRow) +
            ((size_t) x1 * 4);
        uint8_t *dst = destination + ((size_t) row * (size_t) bytesPerRow);
        memcpy(dst, src, bytesPerRow);
    }

    if (visionxShouldTraceTrackedWindow(tracked) &&
        visionxReserveTraceSlot(&visionxCopyTraceCount, VISIONX_COPY_TRACE_LIMIT)) {
        VisionXPixelSample sample = visionxSampleBGRARegion(
            destination,
            width,
            height,
            bytesPerRow,
            0,
            0,
            width,
            height
        );
        visionxLog("snapshot copy region window=%u request=%dx%d+%d+%d clipped=%ux%u+%d+%d window=%ux%u bytesPerRow=%u hash=%08x nz=%u/%u",
                   (unsigned) tracked->window,
                   requestedRegion.width,
                   requestedRegion.height,
                   requestedRegion.x,
                   requestedRegion.y,
                   width,
                   height,
                   x1,
                   y1,
                   regionInfo->window_width,
                   regionInfo->window_height,
                   bytesPerRow,
                   sample.hash,
                   sample.nonzero,
                   sample.samples);
    }

    pthread_mutex_unlock(&info->lock);
    return 1;
}

int
visionx_ddx_window_root_origin(visionx_xid_t window, int32_t *root_x, int32_t *root_y)
{
    VisionXScreenInfo *info = &visionxScreen;

    if (root_x == NULL || root_y == NULL)
        return 0;

    pthread_mutex_lock(&info->lock);
    for (size_t i = 0; i < info->trackedWindowCount; i++) {
        if (info->trackedWindows[i].window == window && info->trackedWindows[i].mapped) {
            *root_x = info->trackedWindows[i].rect.x;
            *root_y = info->trackedWindows[i].rect.y;
            pthread_mutex_unlock(&info->lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&info->lock);
    return 0;
}

static Bool
visionxCreateWindow(WindowPtr pWin)
{
    ScreenPtr pScreen = pWin->drawable.pScreen;
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    Bool result;

    pScreen->CreateWindow = info->createWindow;
    result = (*pScreen->CreateWindow) (pWin);
    info->createWindow = pScreen->CreateWindow;
    pScreen->CreateWindow = visionxCreateWindow;

    if (result && visionxIsTopLevel(pWin)) {
#ifdef COMPOSITE
        visionxRequestTopLevelRedirect(pWin);
#endif
        visionxTrackWindowForWindow(info, pWin, NULL, FALSE);
    }
    else if (result && pWin->parent != NULL && pWin->parent->parent != NULL) {
        WindowPtr topLevel = visionxTopLevelForWindow(pWin);
        PixmapPtr pixmap = topLevel != NULL ? (*pScreen->GetWindowPixmap) (topLevel) : NULL;
        if (visionxIsPrivateWindowPixmap(pScreen, pixmap))
            (*pScreen->SetWindowPixmap) (pWin, pixmap);
    }

    return result;
}

static Bool
visionxDestroyWindow(WindowPtr pWin)
{
    ScreenPtr pScreen = pWin->drawable.pScreen;
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    Bool wasTopLevel = visionxIsTopLevel(pWin);
    XID window = pWin->drawable.id;
    PixmapPtr pixmap = wasTopLevel ? (*pScreen->GetWindowPixmap) (pWin) : NULL;
    Bool result;

    if (wasTopLevel)
        visionxTrackWindowForWindow(info, pWin, NULL, FALSE);

    pScreen->DestroyWindow = info->destroyWindow;
    result = (*pScreen->DestroyWindow) (pWin);
    info->destroyWindow = pScreen->DestroyWindow;
    pScreen->DestroyWindow = visionxDestroyWindow;

    if (result && wasTopLevel) {
        visionxLog("destroy top-level window=%u", (unsigned) window);
        visionxUntrackWindow(info, window);
        if (visionxIsPrivateWindowPixmap(pScreen, pixmap))
            (*pScreen->DestroyPixmap) (pixmap);
        visionx_ddx_destroy_window(info->bridgeScreen, window);
    }

    return result;
}

static Bool
visionxRealizeWindow(WindowPtr pWin)
{
    ScreenPtr pScreen = pWin->drawable.pScreen;
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    Bool result;

    pScreen->RealizeWindow = info->realizeWindow;
    result = (*pScreen->RealizeWindow) (pWin);
    info->realizeWindow = pScreen->RealizeWindow;
    pScreen->RealizeWindow = visionxRealizeWindow;

    if (result && visionxIsTopLevel(pWin)) {
        visionx_rect_t rect = visionxWindowRect(pWin);
#ifdef COMPOSITE
        visionxRequestTopLevelRedirect(pWin);
#endif
        PixmapPtr pixmap = visionxEnsureTopLevelPixmap(pScreen, pWin);
        visionxLog("realize top-level window=%u rect=%dx%d+%d+%d override=%d",
                   (unsigned) pWin->drawable.id,
                   rect.width,
                   rect.height,
                   rect.x,
                   rect.y,
                   pWin->overrideRedirect ? 1 : 0);
        visionxTrackWindowForWindow(info, pWin, pixmap, TRUE);
        visionx_ddx_map_window(
            info->bridgeScreen,
            pWin->drawable.id,
            rect,
            visionxWindowMetadata(pWin)
        );
        visionx_glx_refresh_window_presentation(pWin);
    }

    return result;
}

static Bool
visionxUnrealizeWindow(WindowPtr pWin)
{
    ScreenPtr pScreen = pWin->drawable.pScreen;
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    Bool wasTopLevel = visionxIsTopLevel(pWin);
    XID window = pWin->drawable.id;
    Bool result;

    pScreen->UnrealizeWindow = info->unrealizeWindow;
    result = (*pScreen->UnrealizeWindow) (pWin);
    info->unrealizeWindow = pScreen->UnrealizeWindow;
    pScreen->UnrealizeWindow = visionxUnrealizeWindow;

    if (result && wasTopLevel) {
        visionxLog("unrealize top-level window=%u", (unsigned) window);
        visionxTrackWindowForWindow(info, pWin, NULL, FALSE);
        visionx_ddx_unmap_window(info->bridgeScreen, window);
    }

    return result;
}

static Bool
visionxPositionWindow(WindowPtr pWin, int x, int y)
{
    ScreenPtr pScreen = pWin->drawable.pScreen;
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    Bool result;

    pScreen->PositionWindow = info->positionWindow;
    result = (*pScreen->PositionWindow) (pWin, x, y);
    info->positionWindow = pScreen->PositionWindow;
    pScreen->PositionWindow = visionxPositionWindow;

    if (result && visionxIsTopLevel(pWin) && pWin->realized) {
        visionx_rect_t rect = visionxWindowRect(pWin);
        PixmapPtr pixmap = visionxEnsureTopLevelPixmap(pScreen, pWin);
        visionxLog("position top-level window=%u rect=%dx%d+%d+%d",
                   (unsigned) pWin->drawable.id,
                   rect.width,
                   rect.height,
                   rect.x,
                   rect.y);
        visionxTrackWindowForWindow(info, pWin, pixmap, TRUE);
        visionx_ddx_configure_window(info->bridgeScreen, pWin->drawable.id, rect);
        visionx_glx_refresh_window_presentation(pWin);
    }

    return result;
}

static Bool
visionxIsTrackedProperty(Atom propertyName)
{
    return propertyName == XA_WM_NAME ||
           propertyName == XA_WM_CLASS ||
           propertyName == XA_WM_TRANSIENT_FOR ||
           propertyName == XA_WM_NORMAL_HINTS ||
           propertyName == MakeAtom("_NET_WM_NAME", 12, TRUE) ||
           propertyName == MakeAtom("WM_PROTOCOLS", 12, TRUE);
}

static void
visionxPropertyCallback(CallbackListPtr *pcbl, void *closure, void *data)
{
    PropertyStateRec *rec = (PropertyStateRec *)data;
    VisionXScreenInfo *info = (VisionXScreenInfo *)closure;

    (void)pcbl;

    if (rec == NULL || rec->win == NULL || rec->prop == NULL || info == NULL || info->bridgeScreen == NULL)
        return;

    if (!visionxIsTopLevel(rec->win) || !rec->win->realized || !visionxIsTrackedProperty(rec->prop->propertyName))
        return;

    visionxLog("property update window=%u atom=%u", (unsigned) rec->win->drawable.id, (unsigned) rec->prop->propertyName);
    visionx_ddx_update_window_metadata(
        info->bridgeScreen,
        rec->win->drawable.id,
        visionxWindowMetadata(rec->win)
    );
}

static void
visionxInstallColormap(ColormapPtr pmap)
{
    miInstallColormap(pmap);
}

static void
visionxStoreColors(ColormapPtr pmap, int ndef, xColorItem *pdefs)
{
    (void) pmap;
    (void) ndef;
    (void) pdefs;
}

static Bool
visionxCursorOffScreen(ScreenPtr *ppScreen, int *x, int *y)
{
    (void) ppScreen;
    (void) x;
    (void) y;
    return FALSE;
}

static void
visionxCrossScreen(ScreenPtr pScreen, Bool entering)
{
    (void) pScreen;
    (void) entering;
}

static miPointerScreenFuncRec visionxPointerCursorFuncs = {
    visionxCursorOffScreen,
    visionxCrossScreen,
    miPointerWarpCursor
};

static Bool
visionxCloseScreen(ScreenPtr pScreen)
{
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    visionxLog("close screen");

    pScreen->CloseScreen = info->closeScreen;

    if (info->propertyCallbackRegistered) {
        DeleteCallback(&PropertyStateCallback, visionxPropertyCallback, info);
        info->propertyCallbackRegistered = FALSE;
    }

    visionxReleaseAllTrackedWindows(info);

    visionx_ddx_destroy_screen(info->bridgeScreen);
    info->bridgeScreen = NULL;

    if (pScreen->devPrivate)
        (*pScreen->DestroyPixmap) (pScreen->devPrivate);
    pScreen->devPrivate = NULL;

    pthread_mutex_lock(&info->lock);
    info->trackedWindowCount = 0;
    free(info->framebuffer);
    info->framebuffer = NULL;
    pthread_mutex_unlock(&info->lock);

    return (*pScreen->CloseScreen) (pScreen);
}

static Bool
visionxRRGetInfo(ScreenPtr pScreen, Rotation *rotations)
{
    (void) pScreen;
    *rotations = RR_Rotate_0;
    return TRUE;
}

static Bool
visionxRandRInit(ScreenPtr pScreen)
{
    rrScrPrivPtr pScrPriv;

    if (!RRScreenInit(pScreen))
        return FALSE;

    pScrPriv = rrGetScrPriv(pScreen);
    pScrPriv->rrGetInfo = visionxRRGetInfo;
    return TRUE;
}

static Bool
visionxScreenInit(ScreenPtr pScreen, int argc, char **argv)
{
    VisionXScreenInfo *info = visionxScreenInfo(pScreen);
    int dpix = monitorResolution == 0 ? 100 : monitorResolution;
    int dpiy = monitorResolution == 0 ? 100 : monitorResolution;
    int ret;

    (void) argc;
    (void) argv;

    visionxLog("screen init width=%d height=%d depth=%d", info->width, info->height, info->depth);

    info->paddedBytesWidth = PixmapBytePad(info->width, info->depth);
    info->bitsPerPixel = visionxBitsPerPixel(info->depth);
    info->paddedWidth = info->bitsPerPixel >= 8
        ? info->paddedBytesWidth / (info->bitsPerPixel / 8)
        : info->paddedBytesWidth * 8;

    info->framebuffer = calloc(1, (size_t) info->paddedBytesWidth * (size_t) info->height);
    if (info->framebuffer == NULL) {
        visionxLog("framebuffer allocation failed bytes=%zu errno=%d", (size_t) info->paddedBytesWidth * (size_t) info->height, errno);
        ErrorF("VisionX: framebuffer allocation failed: %s\n", strerror(errno));
        return FALSE;
    }
    pthread_mutex_lock(&info->lock);
    info->trackedWindowCount = 0;
    pthread_mutex_unlock(&info->lock);

    miSetVisualTypesAndMasks(24, (1 << TrueColor), 8, TrueColor,
                             0xff0000, 0x00ff00, 0x0000ff);
    miSetPixmapDepths();

    ret = fbScreenInit(pScreen, info->framebuffer, info->width, info->height,
                       dpix, dpiy, info->paddedWidth, info->bitsPerPixel);
    if (!ret) {
        visionxLog("fbScreenInit failed");
        return FALSE;
    }

    fbPictureInit(pScreen, 0, 0);

    if (!visionxRandRInit(pScreen)) {
        visionxLog("RandR init failed");
        return FALSE;
    }

    pScreen->InstallColormap = visionxInstallColormap;
    pScreen->StoreColors = visionxStoreColors;
    pScreen->blackPixel = 0;
    pScreen->whitePixel = 0x00ffffff;

    miDCInitialize(pScreen, &visionxPointerCursorFuncs);

    if (!fbCreateDefColormap(pScreen)) {
        visionxLog("fbCreateDefColormap failed");
        return FALSE;
    }

    info->bridgeScreen = visionx_ddx_create_screen(
        (uint32_t) info->width,
        (uint32_t) info->height,
        visionx_ddx_current_surface_callbacks()
    );
    if (info->bridgeScreen == NULL) {
        visionxLog("bridge screen creation failed");
        return FALSE;
    }
    visionxLog("bridge screen created");

    info->createWindow = pScreen->CreateWindow;
    info->destroyWindow = pScreen->DestroyWindow;
    info->realizeWindow = pScreen->RealizeWindow;
    info->unrealizeWindow = pScreen->UnrealizeWindow;
    info->positionWindow = pScreen->PositionWindow;
    info->closeScreen = pScreen->CloseScreen;

    pScreen->CreateWindow = visionxCreateWindow;
    pScreen->DestroyWindow = visionxDestroyWindow;
    pScreen->RealizeWindow = visionxRealizeWindow;
    pScreen->UnrealizeWindow = visionxUnrealizeWindow;
    pScreen->PositionWindow = visionxPositionWindow;
    pScreen->CloseScreen = visionxCloseScreen;

    info->propertyCallbackRegistered = AddCallback(&PropertyStateCallback, visionxPropertyCallback, info);
    visionxLog("screen init complete propertyCallbackRegistered=%d", info->propertyCallbackRegistered ? 1 : 0);

    return TRUE;
}

void
InitOutput(ScreenInfo *screen_info, int argc, char **argv)
{
    int i;
    int numFormats = 0;

    visionxLog("InitOutput argc=%d", argc);

    memset(visionxPixmapDepths, 0, sizeof(visionxPixmapDepths));
    visionxPixmapDepths[1] = TRUE;
    visionxPixmapDepths[4] = TRUE;
    visionxPixmapDepths[8] = TRUE;
    visionxPixmapDepths[16] = TRUE;
    visionxPixmapDepths[24] = TRUE;
    visionxPixmapDepths[32] = TRUE;

    for (i = 1; i <= 32; i++) {
        if (visionxPixmapDepths[i]) {
            if (numFormats >= MAXFORMATS)
                FatalError("VisionX: MAXFORMATS is too small\n");
            screen_info->formats[numFormats].depth = i;
            screen_info->formats[numFormats].bitsPerPixel = visionxBitsPerPixel(i);
            screen_info->formats[numFormats].scanlinePad = BITMAP_SCANLINE_PAD;
            numFormats++;
        }
    }

    screen_info->imageByteOrder = IMAGE_BYTE_ORDER;
    screen_info->bitmapScanlineUnit = BITMAP_SCANLINE_UNIT;
    screen_info->bitmapScanlinePad = BITMAP_SCANLINE_PAD;
    screen_info->bitmapBitOrder = BITMAP_BIT_ORDER;
    screen_info->numPixmapFormats = numFormats;

    if (AddScreen(visionxScreenInit, argc, argv) == -1)
        FatalError("VisionX: couldn't add screen\n");
#ifdef VISIONX_GLX_PROVIDER
    VisionXGLXRegisterExtension();
#endif
    visionxLog("InitOutput complete formats=%d", numFormats);
}

void
ddxGiveUp(enum ExitCode error)
{
    (void) error;
}

#ifdef __APPLE__
void
DarwinHandleGUI(int argc, char *argv[])
{
    (void) argc;
    (void) argv;
}
#endif

void
OsVendorInit(void)
{
}

void
OsVendorFatalError(const char *f, va_list args)
{
    (void) f;
    (void) args;
}

#if defined(DDXBEFORERESET)
void
ddxBeforeReset(void)
{
}
#endif

#if INPUTTHREAD
void
ddxInputThreadInit(void)
{
}
#endif

void
ddxUseMsg(void)
{
    ErrorF("-screen WxHxD          set VisionX screen size and depth\n");
}

int
ddxProcessArgument(int argc, char *argv[], int i)
{
    int width;
    int height;
    int depth = VISIONX_DEFAULT_DEPTH;

    if (strcmp(argv[i], "-screen") == 0) {
        CHECK_FOR_REQUIRED_ARGUMENTS(1);
        if (sscanf(argv[i + 1], "%dx%dx%d", &width, &height, &depth) == 3 ||
            sscanf(argv[i + 1], "%dx%d", &width, &height) == 2) {
            visionxScreen.width = width > 0 ? width : VISIONX_DEFAULT_WIDTH;
            visionxScreen.height = height > 0 ? height : VISIONX_DEFAULT_HEIGHT;
            visionxScreen.depth = depth > 0 ? depth : VISIONX_DEFAULT_DEPTH;
            visionxLog("parsed -screen width=%d height=%d depth=%d", visionxScreen.width, visionxScreen.height, visionxScreen.depth);
        }
        return 2;
    }

    (void) argc;
    return 0;
}
