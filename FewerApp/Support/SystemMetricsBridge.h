#ifndef SystemMetricsBridge_h
#define SystemMetricsBridge_h

#include <CoreFoundation/CoreFoundation.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFDictionaryRef destination, CFDictionaryRef source, CFTypeRef unused);
IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef channels, CFMutableDictionaryRef *subscriptionChannels, uint64_t options, CFTypeRef context);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef channels, CFTypeRef context);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current, CFTypeRef context);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

#endif
