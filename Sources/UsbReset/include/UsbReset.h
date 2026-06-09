#ifndef FILMTETHER_USB_RESET_H
#define FILMTETHER_USB_RESET_H

#include <stdint.h>

/**
 * Find a USB device by vendor ID and request a hardware re-enumeration via
 * IOKit. This is functionally equivalent to physically unplugging and
 * replugging the device, the camera's USB stack drops, the body's PTP
 * daemon resets its session, and the device re-appears with a clean state.
 *
 * Returns:
 *   0  = success (re-enumeration requested; device will disappear briefly)
 *  -1  = no matching device found
 *  -2  = IOKit failed to get plug-in interface
 *  -3  = IOKit failed to query USB device interface
 *  -4  = USBDeviceOpen failed (kIOReturnExclusiveAccess if another process holds it)
 *  -5  = USBDeviceReEnumerate failed
 *
 * The caller should wait ~1-2 seconds after a successful call before trying
 * to re-open the device, the kernel needs time to tear down and re-enumerate.
 *
 * Vendor ID for Canon: 0x04A9.
 */
int filmtether_reset_usb_device(uint16_t vendor_id);

#endif
