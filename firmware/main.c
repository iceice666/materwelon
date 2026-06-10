#include "pico/stdlib.h"

void shell_main(void);

int main(void) {
    stdio_init_all();  // initialises USB CDC (stdio_usb) per CMake config
    shell_main();
    return 0;
}
