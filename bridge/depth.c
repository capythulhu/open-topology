// Streams Kinect depth to stdout as raw 640x480 uint16 millimetre frames.
// Nothing else: the Vite plugin in plugin.ts pipes these straight to the browser.

#include <libfreenect/libfreenect.h>
#include <libusb-1.0/libusb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define FRAME_BYTES (640 * 480 * 2)
#define KINECT_VENDOR 0x045e
#define KINECT_CAMERA 0x02ae
#define KINECT_MOTOR 0x02b0

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t frames = 0;

static void stop(int signal) {
    (void)signal;
    running = 0;
}

static void on_depth(freenect_device *device, void *depth, uint32_t timestamp) {
    (void)device;
    (void)timestamp;
    if (fwrite(depth, 1, FRAME_BYTES, stdout) != FRAME_BYTES) running = 0;
    fflush(stdout);
    frames++;
}

// A reader killed mid-stream leaves the device streaming into nothing, after
// which it opens cleanly but never delivers a frame. A usb reset clears that
// without anyone having to reach behind the desk.
static void reset_device(void) {
    libusb_context *usb = NULL;
    if (libusb_init(&usb) < 0) return;

    const uint16_t products[] = {KINECT_CAMERA, KINECT_MOTOR};
    for (size_t i = 0; i < sizeof(products) / sizeof(products[0]); i++) {
        libusb_device_handle *handle = libusb_open_device_with_vid_pid(usb, KINECT_VENDOR, products[i]);
        if (!handle) continue;
        libusb_reset_device(handle);
        libusb_close(handle);
    }

    libusb_exit(usb);
}

static int stream(int wait_for_device) {
    freenect_context *context;
    freenect_device *device;

    if (freenect_init(&context, NULL) < 0) {
        fprintf(stderr, "could not initialise libfreenect\n");
        return -1;
    }

    freenect_set_log_level(context, FREENECT_LOG_FATAL);

    // The 1414 will not stream depth unless the motor interface is opened too:
    // with FREENECT_DEVICE_CAMERA alone libusb loses every packet and no frame
    // ever completes.
    freenect_select_subdevices(context, FREENECT_DEVICE_MOTOR | FREENECT_DEVICE_CAMERA);

    // After a reset the device drops off the bus and re-enumerates, which takes
    // a few seconds.
    for (int tries = 0; freenect_num_devices(context) < 1; tries++) {
        if (!wait_for_device || tries >= 10 || !running) {
            fprintf(stderr, "no kinect found — check the 12V power adapter, the usb cable alone will not do\n");
            freenect_shutdown(context);
            return -1;
        }
        sleep(1);
    }

    if (freenect_open_device(context, &device, 0) < 0) {
        fprintf(stderr, "found a kinect but could not open it — another reader may still hold it\n");
        freenect_shutdown(context);
        return -1;
    }

    freenect_set_depth_mode(device, freenect_find_depth_mode(FREENECT_RESOLUTION_MEDIUM, FREENECT_DEPTH_MM));
    freenect_set_depth_callback(device, on_depth);
    freenect_start_depth(device);

    // freenect_process_events blocks, so the stalled-device check needs the
    // timeout variant to get a look in at all.
    time_t opened = time(NULL);
    struct timeval wait = {1, 0};
    while (running && freenect_process_events_timeout(context, &wait) >= 0) {
        if (frames == 0 && time(NULL) - opened > 5) break;
    }

    freenect_stop_depth(device);
    freenect_close_device(device);
    freenect_shutdown(context);
    return frames;
}

int main(void) {
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    signal(SIGPIPE, stop);

    if (stream(0) > 0 || !running) return 0;

    fprintf(stderr, "kinect sent no frames, resetting it over usb...\n");
    reset_device();

    // The device drops off the bus and comes back, and is briefly enumerable but
    // not yet openable, so give it a few goes.
    for (int attempt = 0; attempt < 4 && running; attempt++) {
        sleep(2);
        if (stream(1) > 0) return 0;
    }

    fprintf(stderr, "still no frames after a reset — unplug the kinect and plug it back in\n");
    return 4;
}
