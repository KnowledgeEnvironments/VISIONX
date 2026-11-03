// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double
now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec / 1000000000.0;
}

typedef enum {
    MODE_TIME,
    MODE_SWAP_STEP,
    MODE_LIST,
    MODE_PRIMITIVES,
    MODE_RESIZE
} TestMode;

static const char *
mode_name(TestMode mode)
{
    switch (mode) {
    case MODE_TIME:
        return "time";
    case MODE_SWAP_STEP:
        return "swap-step";
    case MODE_LIST:
        return "list";
    case MODE_PRIMITIVES:
        return "primitives";
    case MODE_RESIZE:
        return "resize";
    }
    return "unknown";
}

static void
set_projection(int width, int height)
{
    float aspect = height > 0 ? (float) width / (float) height : 1.0f;

    glViewport(0, 0, width, height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    if (aspect >= 1.0f) {
        glOrtho(-aspect, aspect, -1.0, 1.0, -1.0, 1.0);
    } else {
        glOrtho(-1.0, 1.0, -1.0 / aspect, 1.0 / aspect, -1.0, 1.0);
    }

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
}

static void
draw_triangle_and_box(double angle, int width, int height)
{
    set_projection(width, height);
    glRotatef((float) angle, 0.0f, 0.0f, 1.0f);

    glBegin(GL_TRIANGLES);
    glColor3f(1.0f, 0.18f, 0.08f);
    glVertex2f(0.0f, 0.70f);
    glColor3f(0.10f, 0.85f, 0.30f);
    glVertex2f(-0.72f, -0.50f);
    glColor3f(0.25f, 0.45f, 1.0f);
    glVertex2f(0.72f, -0.50f);
    glEnd();

    glLoadIdentity();
    glBegin(GL_LINE_LOOP);
    glColor3f(1.0f, 1.0f, 1.0f);
    glVertex2f(-0.82f, -0.82f);
    glVertex2f(0.82f, -0.82f);
    glVertex2f(0.82f, 0.82f);
    glVertex2f(-0.82f, 0.82f);
    glEnd();
}

static void
draw_frame(double angle, int width, int height)
{
    glClearColor(0.02f, 0.02f, 0.05f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    draw_triangle_and_box(angle, width, height);
}

static GLuint
make_display_list(void)
{
    GLuint list = glGenLists(1);
    if (list == 0)
        return 0;

    glNewList(list, GL_COMPILE);
    glBegin(GL_TRIANGLES);
    glColor3f(1.0f, 0.75f, 0.05f);
    glVertex2f(0.0f, 0.60f);
    glColor3f(0.05f, 0.8f, 1.0f);
    glVertex2f(-0.68f, -0.55f);
    glColor3f(0.9f, 0.1f, 0.4f);
    glVertex2f(0.68f, -0.55f);
    glEnd();

    glBegin(GL_LINE_LOOP);
    glColor3f(1.0f, 1.0f, 1.0f);
    glVertex2f(-0.86f, -0.86f);
    glVertex2f(0.86f, -0.86f);
    glVertex2f(0.86f, 0.86f);
    glVertex2f(-0.86f, 0.86f);
    glEnd();
    glEndList();
    return list;
}

static void
draw_display_list_frame(double angle, int width, int height, GLuint list)
{
    glClearColor(0.04f, 0.01f, 0.03f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    set_projection(width, height);
    glRotatef((float) angle, 0.0f, 0.0f, 1.0f);
    glCallList(list);
}

static void
draw_primitives_frame(double angle, int width, int height)
{
    int spokes = 96;

    glClearColor(0.01f, 0.03f, 0.04f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    set_projection(width, height);
    glRotatef((float) angle, 0.0f, 0.0f, 1.0f);

    glBegin(GL_TRIANGLE_FAN);
    glColor3f(0.15f, 0.12f, 0.20f);
    glVertex2f(0.0f, 0.0f);
    for (int i = 0; i <= spokes; i++) {
        double t = ((double) i / (double) spokes) * M_PI * 2.0;
        glColor3f((float) (0.5 + 0.5 * cos(t)),
                  (float) (0.5 + 0.5 * sin(t)),
                  0.85f);
        glVertex2f((float) (0.70 * cos(t)), (float) (0.70 * sin(t)));
    }
    glEnd();

    glBegin(GL_LINES);
    for (int i = 0; i < spokes; i++) {
        double t = ((double) i / (double) spokes) * M_PI * 2.0;
        glColor3f(1.0f, 1.0f, 1.0f);
        glVertex2f(0.0f, 0.0f);
        glColor3f(0.2f, 0.9f, 0.4f);
        glVertex2f((float) (0.92 * cos(t)), (float) (0.92 * sin(t)));
    }
    glEnd();

    glBegin(GL_POINTS);
    for (int i = 0; i < spokes; i++) {
        double t = ((double) i / (double) spokes) * M_PI * 2.0;
        glColor3f(1.0f, 0.25f, 0.1f);
        glVertex2f((float) (0.55 * cos(t * 3.0)), (float) (0.55 * sin(t * 5.0)));
    }
    glEnd();
}

int
main(int argc, char **argv)
{
    const char *display_name = getenv("DISPLAY");
    int width = 320;
    int height = 240;
    int base_width = 320;
    int base_height = 240;
    TestMode mode = MODE_TIME;
    double step_degrees = 3.0;
    double degrees_per_second = 90.0;
    double stop_after_seconds = 0.0;
    int use_flush = 0;
    int use_finish = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--swap-step") == 0) {
            mode = MODE_SWAP_STEP;
        } else if (strcmp(argv[i], "--time") == 0) {
            mode = MODE_TIME;
        } else if (strcmp(argv[i], "--list") == 0) {
            mode = MODE_LIST;
        } else if (strcmp(argv[i], "--primitives") == 0) {
            mode = MODE_PRIMITIVES;
        } else if (strcmp(argv[i], "--resize") == 0) {
            mode = MODE_RESIZE;
        } else if (strcmp(argv[i], "--flush") == 0) {
            use_flush = 1;
        } else if (strcmp(argv[i], "--finish") == 0) {
            use_finish = 1;
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &width, &height) != 2) {
                fprintf(stderr, "bad --size, expected WIDTHxHEIGHT\n");
                return 2;
            }
            base_width = width;
            base_height = height;
        } else if (strcmp(argv[i], "--step") == 0 && i + 1 < argc) {
            step_degrees = atof(argv[++i]);
        } else if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc) {
            degrees_per_second = atof(argv[++i]);
        } else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
            stop_after_seconds = atof(argv[++i]);
            if (stop_after_seconds < 0.0)
                stop_after_seconds = 0.0;
        } else {
            fprintf(stderr, "usage: %s [--time|--swap-step|--list|--primitives|--resize] [--flush] [--finish] [--size WxH] [--rate deg/sec] [--step deg] [--seconds N]\n", argv[0]);
            return 2;
        }
    }

    Display *display = XOpenDisplay(display_name);
    if (display == NULL) {
        fprintf(stderr, "XOpenDisplay failed for DISPLAY=%s\n", display_name ? display_name : "(null)");
        return 1;
    }

    int screen = DefaultScreen(display);
    int visual_attribs[] = {
        GLX_RGBA,
        GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_DEPTH_SIZE, 16,
        None
    };
    XVisualInfo *visual = glXChooseVisual(display, screen, visual_attribs);
    if (visual == NULL) {
        fprintf(stderr, "glXChooseVisual failed\n");
        return 1;
    }

    Colormap colormap = XCreateColormap(display, RootWindow(display, screen), visual->visual, AllocNone);
    XSetWindowAttributes attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.colormap = colormap;
    attrs.event_mask = ExposureMask | KeyPressMask | StructureNotifyMask;

    Window window = XCreateWindow(display,
                                  RootWindow(display, screen),
                                  80, 80,
                                  (unsigned int) width,
                                  (unsigned int) height,
                                  0,
                                  visual->depth,
                                  InputOutput,
                                  visual->visual,
                                  CWColormap | CWEventMask,
                                  &attrs);
    {
        char title[96];
        snprintf(title, sizeof(title), "uhf-glx-spin %s%s%s",
                 mode_name(mode),
                 use_flush ? " flush" : "",
                 use_finish ? " finish" : "");
        XStoreName(display, window, title);
    }
    XMapWindow(display, window);

    GLXContext context = glXCreateContext(display, visual, NULL, True);
    if (context == NULL) {
        fprintf(stderr, "glXCreateContext failed\n");
        return 1;
    }
    if (!glXMakeCurrent(display, window, context)) {
        fprintf(stderr, "glXMakeCurrent failed\n");
        return 1;
    }

    printf("renderer=%s\n", glGetString(GL_RENDERER));
    printf("version=%s\n", glGetString(GL_VERSION));
    printf("mode=%s flush=%d finish=%d seconds=%.1f\n",
           mode_name(mode),
           use_flush,
           use_finish,
           stop_after_seconds);
    fflush(stdout);

    GLuint list = 0;
    if (mode == MODE_LIST) {
        list = make_display_list();
        if (list == 0) {
            fprintf(stderr, "glGenLists failed\n");
            return 1;
        }
    }

    double start = now_seconds();
    double report_start = start;
    double resize_start = start;
    unsigned long frames = 0;
    double angle = 0.0;
    int running = 1;
    while (running) {
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == ConfigureNotify) {
                width = event.xconfigure.width;
                height = event.xconfigure.height;
            } else if (event.type == KeyPress) {
                running = 0;
            }
        }

        double t = now_seconds();
        if (mode == MODE_RESIZE && t - resize_start >= 0.75) {
            int phase = (int) fmod((t - start) / 0.75, 4.0);
            int new_width = base_width + (phase == 1 ? 120 : phase == 3 ? -80 : 0);
            int new_height = base_height + (phase == 2 ? 90 : phase == 0 ? -50 : 0);
            if (new_width < 120)
                new_width = 120;
            if (new_height < 120)
                new_height = 120;
            XResizeWindow(display, window, (unsigned int) new_width, (unsigned int) new_height);
            resize_start = t;
        }

        if (mode == MODE_SWAP_STEP) {
            angle += step_degrees;
            if (angle >= 360.0)
                angle -= 360.0;
        } else {
            angle = fmod((t - start) * degrees_per_second, 360.0);
        }

        switch (mode) {
        case MODE_LIST:
            draw_display_list_frame(angle, width, height, list);
            break;
        case MODE_PRIMITIVES:
            draw_primitives_frame(angle, width, height);
            break;
        case MODE_TIME:
        case MODE_SWAP_STEP:
        case MODE_RESIZE:
            draw_frame(angle, width, height);
            break;
        }
        if (use_flush)
            glFlush();
        if (use_finish)
            glFinish();
        glXSwapBuffers(display, window);
        frames++;

        if (stop_after_seconds > 0.0 && t - start >= stop_after_seconds)
            running = 0;

        if (t - report_start >= 5.0) {
            printf("%lu frames in %.1f seconds = %.3f FPS angle=%.2f\n",
                   frames,
                   t - report_start,
                   (double) frames / (t - report_start),
                   angle);
            fflush(stdout);
            frames = 0;
            report_start = t;
        }
    }

    glXMakeCurrent(display, None, NULL);
    glXDestroyContext(display, context);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 0;
}
