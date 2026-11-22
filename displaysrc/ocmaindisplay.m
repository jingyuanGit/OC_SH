// ocmaindisplay — keep a chosen monitor as the macOS "main display" (origin 0,0).
//
//   ocmaindisplay --list
//   ocmaindisplay [--vendor 0x1E6D --product 0x5BC0] [--retries 6] [--delay 5] [--verbose]
//   ocmaindisplay --forget
//
// Matching is TWO-STAGE so it survives the monitor landing on a different
// framebuffer after a reboot:
//   1. exact key  "VVVV:PPPP:unit"
//   2. relaxed key "VVVV:PPPP"      (ignores which framebuffer/unit it attached to)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static const unsigned int kDefVendor  = 0x1E6D;  // LG
static const unsigned int kDefProduct = 0x5BC0;
static NSString * const kStatePath = @"/Users/chenjingyuan/Library/Application Support/ocmaindisplay/layout.plist";

static uint32_t activeDisplays(CGDirectDisplayID *ids, uint32_t cap) {
    uint32_t n = 0; CGGetActiveDisplayList(cap, ids, &n); return n;
}
static void stamp(void) {
    time_t t = time(NULL); char b[32];
    strftime(b, sizeof b, "%Y-%m-%d %H:%M:%S", localtime(&t));
    printf("[%s] ", b); fflush(stdout);
}
static NSString *exactKey(CGDirectDisplayID d) {
    return [NSString stringWithFormat:@"%04X:%04X:%u", CGDisplayVendorNumber(d), CGDisplayModelNumber(d), CGDisplayUnitNumber(d)];
}
static NSString *relaxedKey(CGDirectDisplayID d) {
    return [NSString stringWithFormat:@"%04X:%04X", CGDisplayVendorNumber(d), CGDisplayModelNumber(d)];
}
// exact match first, then vendor:product only
static NSDictionary *lookup(NSDictionary *saved, CGDirectDisplayID d) {
    if (!saved) return nil;
    NSDictionary *e = saved[exactKey(d)];
    if (e) return e;
    return saved[relaxedKey(d)];
}
static void printList(void) {
    CGDirectDisplayID ids[16]; uint32_t n = activeDisplays(ids, 16);
    printf("%u active display(s)\n", n);
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf("    id=%-12u %-6s %4zux%-4zu origin=(%-7.0f,%-7.0f) rot=%-3.0f v:p=0x%04X:0x%04X unit=%u\n",
               ids[i], CGDisplayIsMain(ids[i]) ? "[MAIN]" : "",
               CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i]),
               b.origin.x, b.origin.y, CGDisplayRotation(ids[i]),
               CGDisplayVendorNumber(ids[i]), CGDisplayModelNumber(ids[i]), CGDisplayUnitNumber(ids[i]));
    }
    fflush(stdout);
}
static BOOL gNoRecord = NO;
static void recordLayout(CGDirectDisplayID *ids, uint32_t n) {
    if (gNoRecord) return;
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        NSDictionary *rec = @{ @"x": @((int)b.origin.x), @"y": @((int)b.origin.y),
                               @"w": @((int)b.size.width), @"h": @((int)b.size.height),
                               @"main": @(CGDisplayIsMain(ids[i]) ? YES : NO) };
        m[exactKey(ids[i])]   = rec;   // precise
        m[relaxedKey(ids[i])] = rec;   // fallback if the framebuffer index changes
    }
    NSString *dir = [kStatePath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![m writeToFile:kStatePath atomically:YES])
        fprintf(stderr, "[warn] could not write %s\n", [kStatePath UTF8String]);
}
static int applyArrangement(CGDirectDisplayID target, CGDirectDisplayID *ids, uint32_t n, NSDictionary *saved, BOOL verbose) {
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess) { stamp(); printf("CGBeginDisplayConfiguration failed: %d\n", e); return 3; }

    double targetW = CGDisplayBounds(target).size.width;
    NSDictionary *tSaved = lookup(saved, target);
    int32_t targetY = tSaved ? [tSaved[@"y"] intValue] : 0;

    for (uint32_t i = 0; i < n; i++) {
        if (ids[i] == target) continue;
        NSDictionary *s = lookup(saved, ids[i]);
        int32_t nx, ny;
        if (s) { nx = [s[@"x"] intValue]; ny = [s[@"y"] intValue]; }
        else   { nx = (int32_t)targetW;    ny = targetY; }
        if (nx == 0 && ny == 0) nx += (int32_t)targetW;
        e = CGConfigureDisplayOrigin(cfg, ids[i], nx, ny);
        if (e != kCGErrorSuccess) { stamp(); printf("CGConfigureDisplayOrigin(%u -> %d,%d) failed: %d\n", ids[i], nx, ny, e); CGCancelDisplayConfiguration(cfg); return 4; }
        if (verbose) { stamp(); printf("  %s -> (%d,%d)%s\n", [relaxedKey(ids[i]) UTF8String], nx, ny, s ? " [remembered]" : " [fallback]"); }
    }
    e = CGConfigureDisplayOrigin(cfg, target, 0, 0);
    if (e != kCGErrorSuccess) { stamp(); printf("CGConfigureDisplayOrigin(target) failed: %d\n", e); CGCancelDisplayConfiguration(cfg); return 4; }
    if (verbose) { stamp(); printf("  %s -> (0,0) [MAIN]\n", [relaxedKey(target) UTF8String]); }

    e = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
    if (e != kCGErrorSuccess) { stamp(); printf("CGCompleteDisplayConfiguration failed: %d\n", e); return 6; }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        unsigned int wantV = 0, wantP = 0;
        int retries = 6; double delay = 5.0; BOOL verbose = NO, noRecord = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--list")) { stamp(); printList(); return 0; }
            if (!strcmp(argv[i], "--verbose")) verbose = YES;
            if (!strcmp(argv[i], "--no-record")) noRecord = YES;
            if (!strcmp(argv[i], "--forget")) {
                [[NSFileManager defaultManager] removeItemAtPath:kStatePath error:nil];
                stamp(); printf("forgot remembered layout\n"); return 0;
            }
            if (!strcmp(argv[i], "--vendor")  && i+1 < argc) wantV = (unsigned)strtoul(argv[++i], NULL, 0);
            if (!strcmp(argv[i], "--product") && i+1 < argc) wantP = (unsigned)strtoul(argv[++i], NULL, 0);
            if (!strcmp(argv[i], "--retries") && i+1 < argc) retries = atoi(argv[++i]);
            if (!strcmp(argv[i], "--delay")   && i+1 < argc) delay   = atof(argv[++i]);
        }
        gNoRecord = noRecord;
        if (!wantV || !wantP) { wantV = kDefVendor; wantP = kDefProduct; }
        if (retries < 1) retries = 1;

        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
        for (int attempt = 1; attempt <= retries; attempt++) {
            CGDirectDisplayID ids[16];
            uint32_t n = activeDisplays(ids, 16);
            CGDirectDisplayID target = 0;
            for (uint32_t i = 0; i < n; i++)
                if (CGDisplayVendorNumber(ids[i]) == wantV && CGDisplayModelNumber(ids[i]) == wantP) { target = ids[i]; break; }

            if (n == 0) {
                if (verbose) { stamp(); printf("attempt %d/%d: no displays yet\n", attempt, retries); }
            } else if (!target) {
                if (verbose) { stamp(); printf("attempt %d/%d: 0x%04X:0x%04X not connected yet\n", attempt, retries, wantV, wantP); }
            } else if (CGDisplayIsMain(target)) {
                recordLayout(ids, n);
                stamp(); printf("OK: 0x%04X:0x%04X is main display (layout remembered)\n", wantV, wantP);
                if (verbose) printList();
                return 0;
            } else {
                stamp(); printf("attempt %d/%d: 0x%04X:0x%04X is NOT main — restoring %s layout\n",
                                attempt, retries, wantV, wantP, saved ? "remembered" : "default");
                int rc = applyArrangement(target, ids, n, saved, verbose);
                if (rc != 0) return rc;
                usleep(700000);
                uint32_t m = activeDisplays(ids, 16);
                BOOL fixed = NO;
                for (uint32_t i = 0; i < m; i++) if (ids[i] == target && CGDisplayIsMain(ids[i])) fixed = YES;
                if (fixed) {
                    recordLayout(ids, m);
                    stamp(); printf("OK: corrected and layout re-saved\n");
                    if (verbose) printList();
                    return 0;
                }
                stamp(); printf("correction did not stick, retrying\n");
            }
            if (attempt < retries) usleep((useconds_t)(delay * 1e6));
        }
        stamp(); printf("FAILED: 0x%04X:0x%04X never became main\n", wantV, wantP);
        printList();
        return 2;
    }
}
