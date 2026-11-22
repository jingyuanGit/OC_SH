// Dump the live USB topology so we can see where the keyboard sits.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

static void walk(io_registry_entry_t e, int depth, int *count) {
    io_name_t name = {0}; IOObjectGetClass(e, name);
    CFTypeRef prod = IORegistryEntryCreateCFProperty(e, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    CFTypeRef vid  = IORegistryEntryCreateCFProperty(e, CFSTR("idVendor"), kCFAllocatorDefault, 0);
    CFTypeRef pid  = IORegistryEntryCreateCFProperty(e, CFSTR("idProduct"), kCFAllocatorDefault, 0);
    CFTypeRef spd  = IORegistryEntryCreateCFProperty(e, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
    CFTypeRef loc  = IORegistryEntryCreateCFProperty(e, CFSTR("locationID"), kCFAllocatorDefault, 0);

    NSMutableString *ind = [NSMutableString string];
    for (int i = 0; i < depth; i++) [ind appendString:@"  "];

    NSString *p = prod ? [(__bridge id)prod description] : @"";
    if (p.length) {
        unsigned v = vid ? [(__bridge NSNumber *)vid unsignedIntValue] : 0;
        unsigned d = pid ? [(__bridge NSNumber *)pid unsignedIntValue] : 0;
        // locationID 0xRRPP0000 -> root port RR, port PP
        unsigned L = loc ? [(__bridge NSNumber *)loc unsignedIntValue] : 0;
        printf("%s%-46s %04x:%04x  speed=%s loc=0x%08X (root %u port %u)\n",
               [ind UTF8String], [p UTF8String], v, d,
               spd ? [[(__bridge id)spd description] UTF8String] : "?",
               L, (L >> 24) & 0xFF, (L >> 16) & 0xFF);
        (*count)++;
    }
    if (vid) CFRelease(vid); if (pid) CFRelease(pid);
    if (prod) CFRelease(prod); if (spd) CFRelease(spd); if (loc) CFRelease(loc);

    io_iterator_t kids = 0;
    if (IORegistryEntryGetChildIterator(e, kIOServicePlane, &kids) == KERN_SUCCESS) {
        io_registry_entry_t k;
        while ((k = IOIteratorNext(kids))) { walk(k, depth + 1, count); IOObjectRelease(k); }
        IOObjectRelease(kids);
    }
}

int main(void) {
    @autoreleasepool {
        io_iterator_t it = 0;
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
        io_registry_entry_t root;
        int total = 0;
        printf("=== USB devices (tree) ===\n");
        while ((root = IOIteratorNext(it))) {
            walk(root, 0, &total);
            IOObjectRelease(root);
        }
        IOObjectRelease(it);
        printf("\ntotal devices with a product name: %d\n", total);
    }
    return 0;
}
