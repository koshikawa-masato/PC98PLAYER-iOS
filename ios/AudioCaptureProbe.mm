#ifdef PC98PLAYER_TESTING
// SPDX-License-Identifier: MIT
#import "AudioCaptureProbe.h"
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <cstring>
@interface AudioCaptureProbe ()
@property NSURL* directory;
@property NSLock* lock;
@property AVAudioFile* output;
@property AVAudioFile* reference;
@property NSMutableArray* events;
@property NSMutableArray* chunks;
@property NSMutableArray* errors;
@property uint64_t referenceFrames;
@property uint64_t outputFrames;
@property BOOL active;
@end
@implementation AudioCaptureProbe
- (instancetype)initWithDirectory:(NSURL*)directory {
    if((self=[super init])) {
        self.directory=directory;self.lock=[NSLock new];self.events=[NSMutableArray new];self.chunks=[NSMutableArray new];self.errors=[NSMutableArray new];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }return self;
}
- (void)start:(void (^)(NSError*))completion {
    RPScreenRecorder* recorder=RPScreenRecorder.sharedRecorder;recorder.microphoneEnabled=NO;
    [recorder startCaptureWithHandler:^(CMSampleBufferRef sample,RPSampleBufferType type,NSError* error) {
        if(type!=RPSampleBufferTypeAudioApp || error) return;
        [self.lock lock];
        if(self.active) {
            AVAudioFormat* format=[[AVAudioFormat alloc] initWithCMAudioFormatDescription:CMSampleBufferGetFormatDescription(sample)];
            AVAudioFrameCount frames=(AVAudioFrameCount)CMSampleBufferGetNumSamples(sample);
            AVAudioPCMBuffer* pcm=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];pcm.frameLength=frames;
            OSStatus status=CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,0,frames,pcm.mutableAudioBufferList);
            NSError* failure=nil;
            if(!self.output) self.output=[[AVAudioFile alloc] initForWriting:[self.directory URLByAppendingPathComponent:@"output.caf"] settings:format.settings commonFormat:format.commonFormat interleaved:format.interleaved error:&failure];
            if(status==noErr && self.output && [self.output writeFromBuffer:pcm error:&failure]) {
                [self.chunks addObject:@{@"offset":@(self.outputFrames),@"frames":@(frames),@"pts":@(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))),@"rate":@(format.sampleRate)}];self.outputFrames+=frames;
            } else [self.errors addObject:failure.localizedDescription ?: [NSString stringWithFormat:@"copy status %d",(int)status]];
        }
        [self.lock unlock];
    } completionHandler:^(NSError* error) {
        [self.lock lock];self.active=error==nil;[self.lock unlock];
        dispatch_async(dispatch_get_main_queue(),^{ [self event:@"capture-start"];completion(error); });
    }];
}
- (void)appendReference:(const std::vector<int16_t>&)pcm rate:(int)rate {
    [self.lock lock];
    if(self.active && !pcm.empty()) {
        AVAudioFormat* format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:rate channels:2 interleaved:YES];
        NSError* error=nil;
        if(!self.reference) self.reference=[[AVAudioFile alloc] initForWriting:[self.directory URLByAppendingPathComponent:@"reference.caf"] settings:format.settings commonFormat:format.commonFormat interleaved:YES error:&error];
        AVAudioPCMBuffer* buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)(pcm.size()/2)];buffer.frameLength=buffer.frameCapacity;
        std::memcpy(buffer.mutableAudioBufferList->mBuffers[0].mData,pcm.data(),pcm.size()*sizeof(int16_t));
        if([self.reference writeFromBuffer:buffer error:&error]) self.referenceFrames+=buffer.frameLength;
        else [self.errors addObject:error.localizedDescription ?: @"reference write failed"];
    }[self.lock unlock];
}
- (void)event:(NSString*)name {
    [self.lock lock];[self.events addObject:@{@"name":name,@"hostTime":@(CACurrentMediaTime()),@"referenceFrames":@(self.referenceFrames),@"outputFrames":@(self.outputFrames)}];[self.lock unlock];
}
- (void)stop:(void (^)(void))completion {
    [self event:@"capture-stop"];
    [RPScreenRecorder.sharedRecorder stopCaptureWithHandler:^(NSError* error) {
        [self.lock lock];self.active=NO;self.output=nil;self.reference=nil;
        if(error) [self.errors addObject:error.localizedDescription];
        NSDictionary* result=@{@"events":self.events,@"chunks":self.chunks,@"errors":self.errors,@"referenceFrames":@(self.referenceFrames),@"outputFrames":@(self.outputFrames)};
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.directory URLByAppendingPathComponent:@"report.json"] atomically:YES];
        [self.lock unlock];dispatch_async(dispatch_get_main_queue(),completion);
    }];
}
@end

#endif
