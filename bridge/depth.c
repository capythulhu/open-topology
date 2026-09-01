// Streams Kinect depth to stdout as raw 640x480 uint16 millimetre frames.
// Nothing else: the Vite plugin in plugin.ts pipes these straight to the browser.

#include <libfreenect/libfreenect.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define FRAME_BYTES (640 * 480 * 2)

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

int main(void) {
    freenect_context *context;
    freenect_device *device;

    if (freenect_init(&context, NULL) < 0) {
        fprintf(stderr, "could not initialise libfreenect\n");
        return 1;
    }

    freenect_set_log_level(context, FREENECT_LOG_FATAL);
    // The 1414 will not stream depth unless the motor interface is opened too:
    // with FREENECT_DEVICE_CAMERA alone libusb loses every packet and no frame
    // ever completes.
    freenect_select_subdevices(context, FREENECT_DEVICE_MOTOR | FREENECT_DEVICE_CAMERA);

    if (freenect_num_devices(context) < 1) {
        fprintf(stderr, "no kinect found — check the 12V power adapter, the usb cable alone will not do\n");
        freenect_shutdown(context);
        return 2;
    }

    if (freenect_open_device(context, &device, 0) < 0) {
        fprintf(stderr, "found a kinect but could not open it\n");
        freenect_shutdown(context);
        return 3;
    }

    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    signal(SIGPIPE, stop);

    freenect_set_depth_mode(device, freenect_find_depth_mode(FREENECT_RESOLUTION_MEDIUM, FREENECT_DEPTH_MM));
    freenect_set_depth_callback(device, on_depth);
    freenect_start_depth(device);

    // Killing a reader with SIGKILL leaves the device streaming into nothing, and
    // it then opens cleanly but never delivers a frame. Say so rather than hang.
    time_t opened = time(NULL);
    struct timeval wait = {1, 0};
    while (running && freenect_process_events_timeout(context, &wait) >= 0) {
        if (frames == 0 && time(NULL) - opened > 6) {
            fprintf(stderr, "kinect opened but sent no frames — unplug it and plug it back in\n");
            running = 0;
        }
    }

    freenect_stop_depth(device);
    freenect_close_device(device);
    freenect_shutdown(context);
    return 0;
}
