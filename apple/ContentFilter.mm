// SPDX-License-Identifier: MIT
#import "ContentFilter.h"
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <vector>
#include <cstring>
using namespace content_filter;
static NSError* filterError(NSString* message) {
    return [NSError errorWithDomain:@"RetroDOSContentFilter" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

#ifdef PC98PLAYER_TESTING
static NSData* rgbaForTest(UIImage* image) {
    size_t w=CGImageGetWidth(image.CGImage),h=CGImageGetHeight(image.CGImage);
    NSMutableData* bytes=[NSMutableData dataWithLength:w*h*4];CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(bytes.mutableBytes,w,h,8,w*4,colors,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if(context) { CGContextDrawImage(context,CGRectMake(0,0,w,h),image.CGImage);CGContextRelease(context); }
    CGColorSpaceRelease(colors);return bytes;
}
#endif
static NSString* const filterShader=@R"METAL(
#include <metal_stdlib>
using namespace metal;
kernel void cover(texture2d<float,access::read> original [[texture(0)]],
                  texture2d<float,access::read> blurred [[texture(1)]],
                  texture2d<float,access::read> mask [[texture(2)]],
                  texture2d<float,access::write> output [[texture(3)]],
                  constant uint& effect [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    uint2 size=uint2(output.get_width(),output.get_height());if(any(p>=size)) return;
    float4 color=original.read(p);
    if(mask.read(p).r>.5) {
        if(effect==0) color=float4(0,0,0,1);
        else if(effect==1) color=blurred.read(p);
        else { uint block=24;uint2 center=min((p/block)*block+block/2,size-1);color=original.read(center); }
    }
    output.write(color,p);
}
)METAL";
@interface PC98ContentFilter () {
    Settings _settings;
    PresentationGate _gate;
    dispatch_queue_t _worker;
    BOOL _busy;
    UIImage* _pending;
    NSData* _lastSubmittedData;
    void (^_pendingCompletion)(UIImage*,NSString*);
    NSData* _previousPixels;
    UIImage* _previousSource;
    std::vector<Tile> _previousTiles;
    uint64_t _previousGeneration;
    id<MTLTexture> _originalTexture, _blurTexture, _outputTexture, _maskTexture;
    MPSImageGaussianBlur* _blur;
    MLModel* _adultModel;
    MLModel* _harmModel;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commands;
    id<MTLComputePipelineState> _pipeline;
}
@property(nonatomic,readwrite,nullable) NSString* lastError;
@property(nonatomic,readwrite) NSTimeInterval lastProcessingTime;
- (MLModel*)loadModel:(NSString*)name error:(NSError**)error;
@end
#ifdef PC98PLAYER_TESTING
@interface PC98UnavailableModelFilter : PC98ContentFilter
@end
@implementation PC98UnavailableModelFilter
- (MLModel*)loadModel:(NSString*)name error:(NSError**)error {
    if(error)*error=filterError(@"検証用のモデル読込失敗");return nil;
}
@end
#endif
@implementation PC98ContentFilter
- (instancetype)init {
    if((self=[super init])) _worker=dispatch_queue_create("jp.pc98player.content-filter",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    return self;
}
- (Settings)settings { return _settings; }
- (void)configure:(Settings)settings {
    _settings=settings;[self reset];
    dispatch_async(_worker,^{ if(!settings.adult)self->_adultModel=nil;if(!settings.harm)self->_harmModel=nil; });
}
- (void)reset {
    NSAssert(NSThread.isMainThread,@"Content filter presentation is main-thread only");
    _gate.invalidate();_pending=nil;_pendingCompletion=nil;_lastSubmittedData=nil;self.lastError=nil;
}
- (MLModel*)loadModel:(NSString*)name error:(NSError**)error {
    NSURL* url=[NSBundle.mainBundle URLForResource:name withExtension:@"mlmodelc"];
    if(!url) { if(error)*error=filterError(@"検出モデルがありません。画像を表示せず停止しています。");return nil; }
    MLModelConfiguration* configuration=[MLModelConfiguration new];configuration.computeUnits=MLComputeUnitsAll;
    return [MLModel modelWithContentsOfURL:url configuration:configuration error:error];
}
- (BOOL)prepare:(Settings)settings error:(NSError**)error {
    if(settings.adult && !_adultModel) _adultModel=[self loadModel:@"AdultContent" error:error];
    if(settings.adult && !_adultModel) return NO;
    if(settings.harm && !_harmModel) _harmModel=[self loadModel:@"HarmContent" error:error];
    if(settings.harm && !_harmModel) return NO;
    if(!_pipeline) {
        _device=MTLCreateSystemDefaultDevice();_commands=[_device newCommandQueue];
        id<MTLLibrary> library=[_device newLibraryWithSource:filterShader options:nil error:error];
        if(library) _pipeline=[_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"cover"] error:error];
        if(!_pipeline || !_commands) { if(error && !*error)*error=filterError(@"Metalによる保護表示を開始できません。");return NO; }
    }
    return YES;
}
- (MLMultiArray*)predict:(MLModel*)model image:(CGImageRef)image error:(NSError**)error {
    MLImageConstraint* constraint=model.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
    MLFeatureValue* value=[MLFeatureValue featureValueWithCGImage:image constraint:constraint
        options:@{MLFeatureValueImageOptionCropAndScale:@(VNImageCropAndScaleOptionScaleFill)} error:error];
    if(!value)return nil;
    MLDictionaryFeatureProvider* input=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image":value} error:error];
    id<MLFeatureProvider> prediction=input?[model predictionFromFeatures:input error:error]:nil;
    MLMultiArray* scores=[prediction featureValueForName:@"scores"].multiArrayValue;
    if(!scores && error && !*error)*error=filterError(@"検出モデルの出力を読み込めません。");
    return scores;
}
- (BOOL)scores:(Scores*)scores image:(CGImageRef)image settings:(Settings)settings error:(NSError**)error {
    *scores={};
    if(settings.adult) {
        MLMultiArray* a=[self predict:_adultModel image:image error:error];if(a.count!=2)return NO;
        scores->adult=a[0].floatValue;
    }
    if(settings.harm) {
        MLMultiArray* a=[self predict:_harmModel image:image error:error];if(a.count!=2)return NO;
        scores->harm=a[1].floatValue;
    }
    if(!valid(*scores)) { if(error)*error=filterError(@"検出結果が不正なため、画像を保護しています。");return NO; }
    return YES;
}
- (UIImage*)render:(UIImage*)image regions:(const std::vector<Region>&)regions effect:(Effect)effect error:(NSError**)error {
    if(regions.empty()) return image;
    size_t w=CGImageGetWidth(image.CGImage),h=CGImageGetHeight(image.CGImage);
    if(!w || !h || w>4096 || h>4096) { if(error)*error=filterError(@"保護対象の画像サイズが不正です。");return nil; }
    std::vector<uint8_t> rgba(w*h*4),mask(w*h,0);
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap=CGBitmapContextCreate(rgba.data(),w,h,8,w*4,colors,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if(!bitmap) { CGColorSpaceRelease(colors);if(error)*error=filterError(@"保護画像のメモリを確保できません。");return nil; }
    CGContextDrawImage(bitmap,CGRectMake(0,0,w,h),image.CGImage);CGContextRelease(bitmap);
    for(const Region& r:regions) {
        size_t x0=std::min(w,(size_t)std::floor(std::max(0.f,r.x)*w)),y0=std::min(h,(size_t)std::floor(std::max(0.f,r.y)*h));
        size_t x1=std::min(w,(size_t)std::ceil(std::max(0.f,r.x+r.width)*w)),y1=std::min(h,(size_t)std::ceil(std::max(0.f,r.y+r.height)*h));
        for(size_t y=y0;y<y1;++y) if(x1>x0)std::memset(mask.data()+y*w+x0,255,x1-x0);
    }
    if (_originalTexture.width!=w || _originalTexture.height!=h || !_outputTexture || !_maskTexture) {
        MTLTextureDescriptor* desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        desc.storageMode=MTLStorageModeShared;
        _originalTexture=[_device newTextureWithDescriptor:desc];
        _outputTexture=[_device newTextureWithDescriptor:desc];
        _blurTexture=nil;
        desc.pixelFormat=MTLPixelFormatR8Unorm;
        _maskTexture=[_device newTextureWithDescriptor:desc];
    }
    if (effect==Effect::Blur && !_blurTexture) {
        MTLTextureDescriptor* desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        desc.storageMode=MTLStorageModeShared;
        _blurTexture=[_device newTextureWithDescriptor:desc];
    }
    id<MTLTexture> original=_originalTexture, output=_outputTexture, maskTexture=_maskTexture;
    if (!original || !output || !maskTexture || (effect==Effect::Blur && !_blurTexture)) {
        CGColorSpaceRelease(colors);
        if(error)*error=filterError(@"Metalの保護画像を確保できません。");
        return nil;
    }
    [original replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:rgba.data() bytesPerRow:w*4];
    [maskTexture replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:mask.data() bytesPerRow:w];
    id<MTLCommandBuffer> command=[_commands commandBuffer];
    if(effect==Effect::Blur) {
        if (!_blur) {
            _blur=[[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:18];
            _blur.edgeMode=MPSImageEdgeModeClamp;
        }
        [_blur encodeToCommandBuffer:command sourceTexture:original destinationTexture:_blurTexture];
    }
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];[encoder setComputePipelineState:_pipeline];
    [encoder setTexture:original atIndex:0];[encoder setTexture:effect==Effect::Blur?_blurTexture:original atIndex:1];
    [encoder setTexture:maskTexture atIndex:2];[encoder setTexture:output atIndex:3];
    uint32_t mode=(uint32_t)effect;[encoder setBytes:&mode length:sizeof(mode) atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];[encoder endEncoding];
    [command commit];[command waitUntilCompleted];
    if(command.status!=MTLCommandBufferStatusCompleted) { CGColorSpaceRelease(colors);if(error)*error=command.error ?: filterError(@"Metal保護処理に失敗しました。");return nil; }
    [output getBytes:rgba.data() bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
    CFDataRef data=CFDataCreate(kCFAllocatorDefault,rgba.data(),rgba.size());CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);
    CGImageRef result=CGImageCreate(w,h,8,32,w*4,colors,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,nullptr,false,kCGRenderingIntentDefault);
    UIImage* picture=result?[UIImage imageWithCGImage:result]:nil;
    if(result)CGImageRelease(result);CGDataProviderRelease(provider);CFRelease(data);CGColorSpaceRelease(colors);
    if(!picture && error)*error=filterError(@"保護済み画像を作成できません。");return picture;
}
- (UIImage*)filter:(UIImage*)image pixels:(NSData*)pixels generation:(uint64_t)generation
         settings:(Settings)settings error:(NSError**)error {
    if(![self prepare:settings error:error])return nil;
    CGImageRef source=image.CGImage;
    size_t w=CGImageGetWidth(source),h=CGImageGetHeight(source),stride=CGImageGetBytesPerRow(source);
    Scores full;
    if(![self scores:&full image:source settings:settings error:error])return nil;
    CGImageRef previous=_previousSource.CGImage;
    const bool canReuse=generation==_previousGeneration && previous && pixels && _previousPixels &&
        CGImageGetWidth(previous)==w && CGImageGetHeight(previous)==h &&
        CGImageGetBitsPerPixel(source)==32 && CGImageGetBitsPerPixel(previous)==32 &&
        CGImageGetBytesPerRow(previous)==stride && stride>=w*4 &&
        CGImageGetBitmapInfo(source)==CGImageGetBitmapInfo(previous) &&
        pixels.length>=stride*h && _previousPixels.length>=stride*h;
    const int divisions=settings.effect==Effect::Mosaic ? 3 : 2;
    const float overlapX=divisions==3 ? .04f : .10f;
    const float overlapY=divisions==3 ? .04f : .15f;
    std::vector<Tile> tiles;
    tiles.reserve(divisions*divisions);
    for (int row=0;row<divisions;++row) {
        for (int column=0;column<divisions;++column) {
            float x=std::max(0.f,float(column)/divisions-overlapX);
            float y=std::max(0.f,float(row)/divisions-overlapY);
            float right=std::min(1.f,float(column+1)/divisions+overlapX);
            float bottom=std::min(1.f,float(row+1)/divisions+overlapY);
            CGRect cropRect=CGRectIntersection(CGRectMake(0,0,w,h),
                CGRectIntegral(CGRectMake(x*w,y*h,(right-x)*w,(bottom-y)*h)));
            Region region{float(cropRect.origin.x/w),float(cropRect.origin.y/h),
                          float(cropRect.size.width/w),float(cropRect.size.height/h)};
            // Reuse a result only when every pixel in the same crop is identical.
            bool unchanged=canReuse && tiles.size()<_previousTiles.size();
            for (size_t line=0;unchanged && line<(size_t)cropRect.size.height;++line) {
                size_t offset=((size_t)cropRect.origin.y+line)*stride+(size_t)cropRect.origin.x*4;
                unchanged=std::memcmp((const uint8_t*)pixels.bytes+offset,
                    (const uint8_t*)_previousPixels.bytes+offset,(size_t)cropRect.size.width*4)==0;
            }
            Scores score;
            if (unchanged) {
                score=_previousTiles[tiles.size()].scores;
            } else {
                CGImageRef crop=CGImageCreateWithImageInRect(source,cropRect);
                BOOL ok=crop && [self scores:&score image:crop settings:settings error:error];
                if(crop)CGImageRelease(crop);
                if(!ok)return nil;
            }
            tiles.push_back({region,score});
        }
    }
    _previousPixels=pixels;
    _previousSource=image;
    _previousGeneration=generation;
    _previousTiles=tiles;
    return [self render:image regions:regions(full,tiles,settings) effect:settings.effect error:error];
}
- (void)submitImage:(UIImage*)image completion:(void (^)(UIImage*,NSString*))completion {
    NSAssert(NSThread.isMainThread,@"Content filter presentation is main-thread only");
    if(!_settings.enabled()) { completion(image,nil);return; }
    NSData* bytes=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image.CGImage)));
    if(bytes && [_lastSubmittedData isEqualToData:bytes])return;
    _lastSubmittedData=bytes;
    _pending=image;_pendingCompletion=[completion copy];if(!_busy)[self beginPending];
}
- (void)beginPending {
    if(!_pending || _busy)return;
    UIImage* image=_pending;void (^completion)(UIImage*,NSString*)=_pendingCompletion;
    _pending=nil;_pendingCompletion=nil;_busy=YES;
    Settings settings=_settings;Ticket ticket=_gate.issue();
    NSData* pixels=_lastSubmittedData;
    dispatch_async(_worker,^{ @autoreleasepool {
        CFAbsoluteTime started=CFAbsoluteTimeGetCurrent();
        NSError* error=nil;UIImage* result=[self filter:image pixels:pixels generation:ticket.generation settings:settings error:&error];
        NSTimeInterval elapsed=CFAbsoluteTimeGetCurrent()-started;
        NSString* message=result?nil:(error.localizedDescription ?: @"判定できないため画像を保護しています。");
        dispatch_async(dispatch_get_main_queue(),^{
            self->_busy=NO;
            if(self->_gate.accept(ticket)) { self.lastError=message;self.lastProcessingTime=elapsed;completion(result,message); }
            [self beginPending];
        });
    }});
}
#ifdef PC98PLAYER_TESTING
- (void)runSmokeChecks:(void (^)(NSDictionary*,UIImage*))completion {
    dispatch_async(_worker,^{ @autoreleasepool {
        NSMutableDictionary* report=[NSMutableDictionary new];NSError* error=nil;Settings both;both.adult=both.harm=true;
        BOOL prepared=[self prepare:both error:&error];report[@"modelsAndMetalReady"]=@(prepared);
        UIGraphicsImageRendererFormat* format=[UIGraphicsImageRendererFormat new];format.scale=1;format.opaque=YES;
        UIImage* source=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(160,100) format:format] imageWithActions:^(UIGraphicsImageRendererContext* context) {
            [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,160,100));
            for(int x=0;x<160;x+=4) { [[UIColor colorWithRed:(x%12)/12.0 green:.4 blue:.8 alpha:1] setFill];UIRectFill(CGRectMake(x,0,2,100)); }
            [UIColor.redColor setFill];UIRectFill(CGRectMake(0,0,20,20));
        }];
        Scores actual;BOOL predicted=prepared && [self scores:&actual image:source.CGImage settings:both error:&error];
        report[@"bothModelsProduceFiniteScores"]=@(predicted && valid(actual));
        if(predicted)report[@"benignFixtureScores"]=@[@(actual.adult),@(actual.harm)];
        UIImage* mosaic=nil;NSData* originalBytes=rgbaForTest(source);
        for(Effect effect:{Effect::Black,Effect::Blur,Effect::Mosaic}) {
            UIImage* result=prepared?[self render:source regions:{{.25f,.25f,.5f,.5f}} effect:effect error:&error]:nil;
            NSData* a=UIImagePNGRepresentation(source),*b=result?UIImagePNGRepresentation(result):nil;
            report[@[@"metalBlack",@"metalBlur",@"metalMosaic"][(int)effect]]=@(b && ![a isEqualToData:b] && CGImageGetWidth(result.CGImage)==160);
            if(result) {
                NSData* resultBytes=rgbaForTest(result);const uint8_t* original=(const uint8_t*)originalBytes.bytes;const uint8_t* modified=(const uint8_t*)resultBytes.bytes;
                BOOL outside=YES,black=YES,blocks=YES;double beforeVariation=0,afterVariation=0;
                for(int y=0;y<100;++y)for(int x=0;x<160;++x) {
                    size_t p=(y*160+x)*4;BOOL covered=x>=40 && x<120 && y>=25 && y<75;
                    if(!covered)outside &= std::memcmp(original+p,modified+p,4)==0;
                    if(covered) {
                        black &= modified[p]==0 && modified[p+1]==0 && modified[p+2]==0 && modified[p+3]==255;
                        if(x+1<120 && x/24==(x+1)/24)blocks &= std::memcmp(modified+p,modified+p+4,4)==0;
                        if(x+1<120) { beforeVariation+=std::abs((int)original[p]-(int)original[p+4]);afterVariation+=std::abs((int)modified[p]-(int)modified[p+4]); }
                    }
                }
                report[[@"unmaskedPixelsPreserved" stringByAppendingFormat:@"%d",(int)effect]]=@(outside);
                if(effect==Effect::Black)report[@"maskedBlackIsOpaque"]=@(black);
                if(effect==Effect::Mosaic)report[@"mosaicBlocksAreUniform"]=@(blocks);
                if(effect==Effect::Blur)report[@"blurReducesFineDetail"]=@(beforeVariation>0 && afterVariation<beforeVariation*.5);
            }
            if(effect==Effect::Mosaic)mosaic=result;
        }
        if(error)report[@"error"]=error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(),^{
            if(!prepared) { completion(report,mosaic ?: source);return; }
            Settings original=self.settings;
            Settings mosaicSettings=both;
            mosaicSettings.effect=Effect::Mosaic;
            [self configure:mosaicSettings];
            __block BOOL staleDelivered=NO,delivered=NO;
            [self submitImage:source completion:^(UIImage* image,NSString* message) { staleDelivered=YES; }];
            report[@"enabledSubmitDoesNotRevealSynchronously"]=@(!staleDelivered);
            [self reset];
            [self submitImage:source completion:^(UIImage* image,NSString* message) {
                delivered=YES;report[@"staleGenerationWasDiscarded"]=@(!staleDelivered);
                report[@"completeAsyncModelPipeline"]=@(image!=nil && message==nil);
                report[@"processingMilliseconds"]=@(self.lastProcessingTime*1000);
                [self configure:original];
                PC98UnavailableModelFilter* unavailable=[PC98UnavailableModelFilter new];[unavailable configure:both];
                [unavailable submitImage:source completion:^(UIImage* failed,NSString* message) {
                    report[@"missingModelFailsClosed"]=@(failed==nil && message.length>0);
                    __block BOOL unexpected=NO;
                    [unavailable submitImage:source completion:^(UIImage* image,NSString* error) { unexpected=YES; }];
                    report[@"deduplicatedFailureRetainsError"]=@(!unexpected && unavailable.lastError.length>0);
                    completion(report,mosaic ?: source);
                }];
            }];
            report[@"replacementWaitsForInference"]=@(!delivered);
        });
    }});
}
#endif
@end
