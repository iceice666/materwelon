#include "pico/stdlib.h"
#include "hardware/gpio.h"
#include "hardware/adc.h"

void shell_main(void);

// The Zig shell declares these as extern. The underlying pico-sdk functions
// are static inline in the SDK headers, so there is no symbol to link
// against — these shims export real symbols for them. (gpio_init and
// adc_init are real SDK functions and need no shim.)
void shim_gpio_set_dir(uint gpio, bool out)  { gpio_set_dir(gpio, out); }
void shim_gpio_put(uint gpio, bool value)    { gpio_put(gpio, value); }
bool shim_gpio_get(uint gpio)                { return gpio_get(gpio); }
void shim_adc_gpio_init(uint gpio)           { adc_gpio_init(gpio); }
void shim_adc_select_input(uint input)       { adc_select_input(input); }
uint16_t shim_adc_read(void)                 { return adc_read(); }

int main(void) {
    stdio_init_all();  // initialises serial I/O per CMake config
    shell_main();
    return 0;
}
