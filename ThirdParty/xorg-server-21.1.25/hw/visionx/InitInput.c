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

#include <X11/X.h>
#include <X11/Xproto.h>
#include <X11/Xos.h>
#include <X11/keysym.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include "CXOrgBridge/visionx_ddx.h"
#include "dix.h"
#include "exevents.h"
#include "extinit.h"
#include "input.h"
#include "inputstr.h"
#include "mi.h"
#include "mipointer.h"
#include "os.h"
#include "scrnintstr.h"
#include "window.h"
#include "windowstr.h"
#include "xkbsrv.h"
#include "xserver-properties.h"

static DeviceIntPtr visionxPointerDevice = NULL;
static DeviceIntPtr visionxKeyboardDevice = NULL;
static int visionxInputWakePipe[2] = { -1, -1 };
static pthread_mutex_t visionxPendingFocusLock = PTHREAD_MUTEX_INITIALIZER;
static Window visionxPendingFocusWindow = 0;
static int visionxHasPendingFocusWindow = 0;
static int visionxPendingFocusShouldRaise = 0;

static void visionxLog(const char *format, ...) _X_ATTRIBUTE_PRINTF(1, 2);
static void visionxProcessPendingFocus(void);

static void
visionxLog(const char *format, ...)
{
    va_list args;
    fprintf(stderr, "[VisionX DDX] ");
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fprintf(stderr, "\n");
    fflush(stderr);
}

static void
visionxDrainInputWakePipe(int fd, int ready, void *data)
{
    char buffer[64];

    (void) ready;
    (void) data;

    while (read(fd, buffer, sizeof(buffer)) > 0) {
    }

    visionxProcessPendingFocus();
}

static void
visionxProcessPendingFocus(void)
{
    Window focusWindow = 0;
    int hasFocusWindow = 0;
    int shouldRaise = 0;
    int status;

    pthread_mutex_lock(&visionxPendingFocusLock);
    if (visionxHasPendingFocusWindow) {
        focusWindow = visionxPendingFocusWindow;
        shouldRaise = visionxPendingFocusShouldRaise;
        visionxHasPendingFocusWindow = 0;
        visionxPendingFocusShouldRaise = 0;
        hasFocusWindow = 1;
    }
    pthread_mutex_unlock(&visionxPendingFocusLock);

    if (!hasFocusWindow)
        return;
    if (visionxKeyboardDevice == NULL || !visionxKeyboardDevice->public.on)
        return;

    if (shouldRaise) {
        WindowPtr windowPtr = NULL;
        int lookupStatus = dixLookupWindow(&windowPtr,
                                           focusWindow,
                                           serverClient,
                                           DixManageAccess);
        if (lookupStatus == Success && windowPtr != NULL && windowPtr->parent != NULL) {
            XID vlist[1] = { Above };
            int configureStatus = ConfigureWindow(windowPtr,
                                                  CWStackMode,
                                                  vlist,
                                                  serverClient);
            visionxLog("raise window=%u status=%d",
                       (unsigned) focusWindow,
                       configureStatus);
        }
        else {
            visionxLog("raise window=%u lookup=%d skipped",
                       (unsigned) focusWindow,
                       lookupStatus);
        }
    }

    status = SetInputFocus(serverClient,
                           visionxKeyboardDevice,
                           focusWindow,
                           RevertToPointerRoot,
                           CurrentTime,
                           FALSE);
    visionxLog("focus window=%u status=%d", (unsigned) focusWindow, status);
}

static void
visionxPokeInputQueue(void)
{
    const char byte = 0;

    if (visionxInputWakePipe[1] >= 0) {
        ssize_t result = write(visionxInputWakePipe[1], &byte, 1);
        (void) result;
    }
}

static void
visionxCloseInputWakePipe(void)
{
    if (visionxInputWakePipe[0] >= 0) {
        RemoveNotifyFd(visionxInputWakePipe[0]);
        close(visionxInputWakePipe[0]);
        visionxInputWakePipe[0] = -1;
    }
    if (visionxInputWakePipe[1] >= 0) {
        close(visionxInputWakePipe[1]);
        visionxInputWakePipe[1] = -1;
    }
}

static void
visionxOpenInputWakePipe(void)
{
    if (visionxInputWakePipe[0] >= 0)
        return;

    if (pipe(visionxInputWakePipe) != 0) {
        visionxLog("input wake pipe failed errno=%d", errno);
        visionxInputWakePipe[0] = -1;
        visionxInputWakePipe[1] = -1;
        return;
    }

    fcntl(visionxInputWakePipe[0], F_SETFL, O_NONBLOCK);
    fcntl(visionxInputWakePipe[1], F_SETFL, O_NONBLOCK);
    if (!SetNotifyFd(visionxInputWakePipe[0], visionxDrainInputWakePipe, X_NOTIFY_READ, NULL)) {
        visionxLog("input wake pipe notify registration failed");
        visionxCloseInputWakePipe();
        return;
    }

    visionxLog("input wake pipe registered readFd=%d writeFd=%d",
               visionxInputWakePipe[0],
               visionxInputWakePipe[1]);
}

void
ProcessInputEvents(void)
{
    mieqProcessInputEvents();
}

void
DDXRingBell(int volume, int pitch, int duration)
{
    (void) volume;
    (void) pitch;
    (void) duration;
}

static int
visionxKeyboardProc(DeviceIntPtr pDevice, int onoff)
{
    DevicePtr pDev = (DevicePtr) pDevice;

    switch (onoff) {
    case DEVICE_INIT:
        visionxLog("keyboard init");
        InitKeyboardDeviceStruct(pDevice, NULL, NULL, NULL);
        break;
    case DEVICE_ON:
        visionxLog("keyboard on");
        pDev->on = TRUE;
        break;
    case DEVICE_OFF:
        visionxLog("keyboard off");
        pDev->on = FALSE;
        break;
    case DEVICE_CLOSE:
        visionxLog("keyboard close");
        break;
    }

    return Success;
}

static int
visionxPointerProc(DeviceIntPtr pDevice, int onoff)
{
#define NBUTTONS 5
#define NAXES 2

    BYTE map[NBUTTONS + 1];
    DevicePtr pDev = (DevicePtr) pDevice;
    Atom buttonLabels[NBUTTONS] = { 0 };
    Atom axisLabels[NAXES] = { 0 };

    switch (onoff) {
    case DEVICE_INIT:
        visionxLog("pointer init");
        map[1] = 1;
        map[2] = 2;
        map[3] = 3;
        map[4] = 4;
        map[5] = 5;

        buttonLabels[0] = XIGetKnownProperty(BTN_LABEL_PROP_BTN_LEFT);
        buttonLabels[1] = XIGetKnownProperty(BTN_LABEL_PROP_BTN_MIDDLE);
        buttonLabels[2] = XIGetKnownProperty(BTN_LABEL_PROP_BTN_RIGHT);
        buttonLabels[3] = XIGetKnownProperty(BTN_LABEL_PROP_BTN_WHEEL_UP);
        buttonLabels[4] = XIGetKnownProperty(BTN_LABEL_PROP_BTN_WHEEL_DOWN);

        axisLabels[0] = XIGetKnownProperty(AXIS_LABEL_PROP_ABS_X);
        axisLabels[1] = XIGetKnownProperty(AXIS_LABEL_PROP_ABS_Y);

        InitPointerDeviceStruct(pDev, map, NBUTTONS, buttonLabels,
                                (PtrCtrlProcPtr) NoopDDA,
                                GetMotionHistorySize(), NAXES, axisLabels);
        break;
    case DEVICE_ON:
        visionxLog("pointer on");
        pDev->on = TRUE;
        break;
    case DEVICE_OFF:
        visionxLog("pointer off");
        pDev->on = FALSE;
        break;
    case DEVICE_CLOSE:
        visionxLog("pointer close");
        break;
    }

    return Success;

#undef NAXES
#undef NBUTTONS
}

void
InitInput(int argc, char *argv[])
{
    DeviceIntPtr pointer;
    DeviceIntPtr keyboard;
    Atom type;

    (void) argc;
    (void) argv;

    visionxLog("InitInput argc=%d", argc);
    pointer = AddInputDevice(serverClient, visionxPointerProc, TRUE);
    keyboard = AddInputDevice(serverClient, visionxKeyboardProc, TRUE);
    visionxPointerDevice = pointer;
    visionxKeyboardDevice = keyboard;

    type = MakeAtom(XI_MOUSE, sizeof(XI_MOUSE) - 1, TRUE);
    AssignTypeAndName(pointer, type, "VisionX pointer");

    type = MakeAtom(XI_KEYBOARD, sizeof(XI_KEYBOARD) - 1, TRUE);
    AssignTypeAndName(keyboard, type, "VisionX keyboard");

    (void) mieqInit();
    visionxOpenInputWakePipe();
    visionxLog("InitInput complete");
}

void
CloseInput(void)
{
    visionxLog("CloseInput");
    visionxCloseInputWakePipe();
    pthread_mutex_lock(&visionxPendingFocusLock);
    visionxPendingFocusWindow = 0;
    visionxHasPendingFocusWindow = 0;
    pthread_mutex_unlock(&visionxPendingFocusLock);
    visionxPointerDevice = NULL;
    visionxKeyboardDevice = NULL;
    mieqFini();
}

int
visionx_ddx_queue_pointer_event(visionx_pointer_event_kind_t kind, uint8_t detail, int32_t root_x, int32_t root_y)
{
    int type;
    int button = detail;
    ValuatorMask *mask;

    if (visionxPointerDevice == NULL || !visionxPointerDevice->public.on)
        return 0;

    switch (kind) {
    case VISIONX_POINTER_EVENT_MOTION:
    case VISIONX_POINTER_EVENT_ENTER:
        type = MotionNotify;
        button = 0;
        break;
    case VISIONX_POINTER_EVENT_BUTTON_PRESS:
        type = ButtonPress;
        break;
    case VISIONX_POINTER_EVENT_BUTTON_RELEASE:
        type = ButtonRelease;
        break;
    case VISIONX_POINTER_EVENT_LEAVE:
        return 1;
    default:
        return 0;
    }

    mask = valuator_mask_new(2);
    if (mask == NULL)
        return 0;

    valuator_mask_set(mask, 0, root_x);
    valuator_mask_set(mask, 1, root_y);

    input_lock();
    QueuePointerEvents(visionxPointerDevice,
                       type,
                       button,
                       POINTER_ABSOLUTE | POINTER_SCREEN,
                       mask);
    visionxPokeInputQueue();
    input_unlock();

    valuator_mask_free(&mask);
    return 1;
}

int
visionx_ddx_queue_key_event(visionx_key_event_kind_t kind, uint8_t keycode)
{
    int type;

    if (visionxKeyboardDevice == NULL || !visionxKeyboardDevice->public.on)
        return 0;

    switch (kind) {
    case VISIONX_KEY_EVENT_PRESS:
        type = KeyPress;
        break;
    case VISIONX_KEY_EVENT_RELEASE:
        type = KeyRelease;
        break;
    default:
        return 0;
    }

    input_lock();
    QueueKeyboardEvents(visionxKeyboardDevice, type, keycode);
    visionxPokeInputQueue();
    input_unlock();

    return 1;
}

int
visionx_ddx_focus_window(visionx_xid_t window)
{
    return visionx_ddx_activate_window(window, 0);
}

int
visionx_ddx_activate_window(visionx_xid_t window, int should_raise)
{
    if (visionxKeyboardDevice == NULL || !visionxKeyboardDevice->public.on)
        return 0;

    pthread_mutex_lock(&visionxPendingFocusLock);
    visionxPendingFocusWindow = (Window) window;
    visionxPendingFocusShouldRaise = should_raise != 0;
    visionxHasPendingFocusWindow = 1;
    pthread_mutex_unlock(&visionxPendingFocusLock);

    visionxPokeInputQueue();
    return 1;
}
