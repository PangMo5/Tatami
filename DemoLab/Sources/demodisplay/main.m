// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
// Lab-only helper; these private CoreGraphics interfaces are not linked into Tatami.
// API reference: https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly) CGDirectDisplayID displayID;
- (id)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
  signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
  int seconds = argc > 1 ? atoi(argv[1]) : 300;
  if (seconds < 1 || seconds > 3600) return 64;
  NSLog(@"class=%@", NSClassFromString(@"CGVirtualDisplay"));
  CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
  descriptor.name = @"Tatami Lab Secondary";
  descriptor.maxPixelsWide = 1920; descriptor.maxPixelsHigh = 1200;
  descriptor.sizeInMillimeters = CGSizeMake(508, 318);
  descriptor.vendorID = 0x5050; descriptor.productID = 0x1001; descriptor.serialNum = 42;
  [descriptor setDispatchQueue:dispatch_get_main_queue()];
  CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
  if (!display) { NSLog(@"creation failed"); return 2; }
  CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
  settings.hiDPI = 0;
  settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1200 refreshRate:60]];
  BOOL applied = [display applySettings:settings];
  NSLog(@"id=%u applied=%d", display.displayID, applied);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  [[NSRunLoop currentRunLoop] runUntilDate:deadline];
  CGDirectDisplayID ids[16]; uint32_t count = 0;
  CGGetOnlineDisplayList(16, ids, &count);
  for (uint32_t i = 0; i < count; i++) NSLog(@"display=%u active=%d bounds=%@", ids[i], CGDisplayIsActive(ids[i]), NSStringFromRect(CGDisplayBounds(ids[i])));
  NSLog(@"online=%u", count);
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
  (void)display.displayID;
  return applied && count > 1 ? 0 : 3;
}}
