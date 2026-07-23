@import UIKit;
#include <fcntl.h>
#include <unistd.h>

static void write_load_marker(void) {
    const char marker[] = "SpringBoardTweak loaded\n";
    int fd = open("/tmp/SpringBoardTweak.loaded", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, marker, sizeof(marker) - 1);
        close(fd);
    }
}

__attribute__((constructor)) static void initializeTweak(void) {
    // Keep the constructor side-effect free. SpringBoard may load this dylib
    // before UIKit has a usable window or view controller.
    write_load_marker();
}
