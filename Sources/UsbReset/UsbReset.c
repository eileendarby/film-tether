#include "UsbReset.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

int filmtether_reset_usb_device(uint16_t vendor_id) {
    // Try both modern (IOUSBHostDevice) and legacy (IOUSBDevice) USB class names.
    // macOS 11+ migrated to IOUSBHostDevice; legacy IOUSBLib's IOServiceMatching by
    // class "IOUSBDevice" no longer finds USB devices on modern macOS even though
    // the underlying IOUSBDeviceInterface plug-in still works for re-enumeration.
    const char *class_names[] = { "IOUSBHostDevice", kIOUSBDeviceClassName };
    io_service_t device = IO_OBJECT_NULL;

    // Walk all USB devices in the registry (no vendor filter), we'll inspect each
    // one's idVendor property in-loop. This avoids matching-dictionary key compatibility
    // issues that have bitten us across macOS versions (kUSBVendorID, kUSBHostMatchingPropertyVendorID,
    // idVendor as int vs as string, etc).
    for (int i = 0; i < 2 && device == IO_OBJECT_NULL; i++) {
        CFMutableDictionaryRef matchingDict = IOServiceMatching(class_names[i]);
        if (!matchingDict) continue;

        io_iterator_t iter = IO_OBJECT_NULL;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter);
        if (kr != KERN_SUCCESS) continue;

        io_service_t candidate = IO_OBJECT_NULL;
        while ((candidate = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            CFTypeRef vidRef = IORegistryEntryCreateCFProperty(
                candidate, CFSTR("idVendor"), kCFAllocatorDefault, 0
            );
            if (vidRef && CFGetTypeID(vidRef) == CFNumberGetTypeID()) {
                SInt32 candidate_vid = 0;
                CFNumberGetValue((CFNumberRef)vidRef, kCFNumberSInt32Type, &candidate_vid);
                if ((uint16_t)candidate_vid == vendor_id) {
                    if (vidRef) CFRelease(vidRef);
                    device = candidate;
                    break;
                }
            }
            if (vidRef) CFRelease(vidRef);
            IOObjectRelease(candidate);
        }
        IOObjectRelease(iter);
    }

    if (device == IO_OBJECT_NULL) {
        fprintf(stderr, "filmtether_reset_usb_device: no IOUSBHostDevice / IOUSBDevice matched vendor 0x%04x\n", vendor_id);
        return -1;
    }
    fprintf(stderr, "filmtether_reset_usb_device: matched device, opening...\n");

    int result = 0;
    kern_return_t kr;

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(
        device,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    IOObjectRelease(device);
    if (kr != KERN_SUCCESS || plugIn == NULL) return -2;

    IOUSBDeviceInterface **devIntf = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(
        plugIn,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        (LPVOID *)&devIntf
    );
    (*plugIn)->Release(plugIn);
    if (hr != S_OK || devIntf == NULL) return -3;

    // Open with arbitration, kIOReturnExclusiveAccess if another process (e.g. ptpcamerad
    // or libgphoto2 *in this same process*) has the device open. Seize forcibly takes it.
    kr = (*devIntf)->USBDeviceOpen(devIntf);
    if (kr != kIOReturnSuccess) {
        kr = (*devIntf)->USBDeviceOpenSeize(devIntf);
        if (kr != kIOReturnSuccess) {
            (*devIntf)->Release(devIntf);
            return -4;
        }
    }

    // USBDeviceReEnumerate is the heavy hammer: it forces the kernel to disconnect
    // the device and re-enumerate it from scratch, functionally equivalent to a
    // physical unplug+replug. The body's PTP daemon resets unconditionally on this.
    //
    // We tried the lighter ResetDevice first but it doesn't go deep enough, bus
    // reset alone leaves the 7D's wedged PTP daemon still wedged.
    //
    // Note: the device handle becomes invalid after ReEnumerate succeeds (the
    // io_service_t we matched is gone, replaced by a new one on the re-enumerate).
    // So we don't call USBDeviceClose post-success.
    kr = (*devIntf)->USBDeviceReEnumerate(devIntf, 0);
    if (kr != kIOReturnSuccess) {
        // Fall back to ResetDevice, at least the bus gets reset even if the body
        // doesn't fully reinit.
        kern_return_t reset_kr = (*devIntf)->ResetDevice(devIntf);
        if (reset_kr != kIOReturnSuccess) result = -5;
        (*devIntf)->USBDeviceClose(devIntf);
    }
    (*devIntf)->Release(devIntf);

    return result;
}
