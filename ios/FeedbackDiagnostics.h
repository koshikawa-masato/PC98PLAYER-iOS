// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>

// Freeze the allowlisted diagnostic snapshot at capture time, not at send time.
// The existing support body transports JSON without changing the live protocol.
static inline NSString* PC98FeedbackDiagnosticJSON(NSDictionary* snapshot) {
    if (!snapshot.count || ![NSJSONSerialization isValidJSONObject:snapshot]) return nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:snapshot
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data.length || data.length > 6000) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static inline NSString* PC98FeedbackBody(NSString* body, NSString* diagnostics, BOOL include) {
    if (include && diagnostics.length)
        return [body stringByAppendingFormat:@"\n\n診断情報（撮影・エラー発生時）\n```json\n%@\n```", diagnostics];
    return body;
}
