#include <libfreenect/libfreenect.h>
#include <libusb-1.0/libusb.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define FRAME_BYTES (640 * 480 * 2)
#define KINECT_VENDOR 0x045e
#define KINECT_CAMERA 0x02ae
#define KINECT_MOTOR 0x02b0
#define LOCK_PATH "/tmp/open-topology-kinect.lock"

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t frames = 0;

static int lock_device(void) {
    int fd = open(LOCK_PATH, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return 0;
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) return 1;
    close(fd);
    return -1;
}

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

    freenect_select_subdevices(context, FREENECT_DEVICE_MOTOR | FREENECT_DEVICE_CAMERA);

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

    if (lock_device() < 0) {
        fprintf(stderr, "another reader already has the kinect — close the other tab or dev server using it\n");
        return 5;
    }

    if (stream(0) > 0 || !running) return 0;

    fprintf(stderr, "kinect sent no frames, resetting it over usb...\n");
    reset_device();

    for (int attempt = 0; attempt < 4 && running; attempt++) {
        sleep(2);
        if (stream(1) > 0) return 0;
    }

    fprintf(stderr, "still no frames after a reset — unplug the kinect and plug it back in\n");
    return 4;
}
