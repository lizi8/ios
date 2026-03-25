#import "DCFaceDetectionModule.h"

@interface DCFaceDetectionModule ()

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t cameraQueue;
@property (nonatomic, assign) NSTimeInterval callbackInterval;
@property (nonatomic, assign) NSTimeInterval lastCallbackTs;
@property (nonatomic, copy) UniModuleKeepAliveCallback keepAliveCallback;
@property (nonatomic, assign) BOOL running;

@end

@implementation DCFaceDetectionModule

UNI_EXPORT_METHOD(@selector(startDetect:callback:))
UNI_EXPORT_METHOD(@selector(stopDetect))

- (instancetype)init {
    self = [super init];
    if (self) {
        _cameraQueue = dispatch_queue_create("face.detect.camera.queue", DISPATCH_QUEUE_SERIAL);
        _callbackInterval = 0.3;
        _lastCallbackTs = 0;
        _running = NO;
    }
    return self;
}

- (void)startDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    self.keepAliveCallback = callback;

    NSNumber *intervalMs = options[@"intervalMs"];
    if ([intervalMs isKindOfClass:[NSNumber class]] && intervalMs.doubleValue > 0) {
        self.callbackInterval = intervalMs.doubleValue / 1000.0;
    } else {
        self.callbackInterval = 0.3;
    }

    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (authStatus == AVAuthorizationStatusDenied || authStatus == AVAuthorizationStatusRestricted) {
        [self emitError:@"未获得摄像头权限"];
        return;
    }

    if (authStatus == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!granted) {
                    [weakSelf emitError:@"用户拒绝了摄像头权限"];
                    return;
                }
                [weakSelf setupAndStartSession];
            });
        }];
        return;
    }

    [self setupAndStartSession];
}

- (void)stopDetect {
    if (!self.running) return;
    self.running = NO;

    if (self.session && self.session.isRunning) {
        [self.session stopRunning];
    }
    self.session = nil;
    self.lastCallbackTs = 0;
}

- (void)setupAndStartSession {
    if (self.running) {
        [self emitInfoHasFace:NO facing:NO faces:@[] message:@"检测已在运行"];
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        session.sessionPreset = AVCaptureSessionPreset640x480;
    }

    NSError *inputError = nil;
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&inputError];
    if (inputError || !input || ![session canAddInput:input]) {
        [self emitError:@"创建摄像头输入失败"];
        return;
    }
    [session addInput:input];

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    output.alwaysDiscardsLateVideoFrames = YES;
    [output setSampleBufferDelegate:self queue:self.cameraQueue];

    if (![session canAddOutput:output]) {
        [self emitError:@"创建视频输出失败"];
        return;
    }
    [session addOutput:output];

    AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
    if ([connection isVideoOrientationSupported]) {
        connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }

    self.session = session;
    self.running = YES;
    [self.session startRunning];
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!self.running) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.lastCallbackTs > 0 && now - self.lastCallbackTs < self.callbackInterval) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    VNDetectFaceRectanglesRequest *request = [[VNDetectFaceRectanglesRequest alloc] init];
    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer orientation:kCGImagePropertyOrientationRight options:@{}];

    NSError *error = nil;
    BOOL success = [handler performRequests:@[request] error:&error];
    if (!success || error) {
        [self emitError:@"Vision 人脸识别失败"];
        return;
    }

    NSArray<VNFaceObservation *> *results = request.results ?: @[];
    NSMutableArray *faces = [NSMutableArray array];
    BOOL hasFace = results.count > 0;
    BOOL facing = NO;

    for (VNFaceObservation *obs in results) {
        CGRect b = obs.boundingBox;
        [faces addObject:@{
            @"x": @(b.origin.x),
            @"y": @(b.origin.y),
            @"width": @(b.size.width),
            @"height": @(b.size.height)
        }];

        // 简单“是否正对屏幕”判断：yaw/roll 接近 0 认为在正对
        if (@available(iOS 13.0, *)) {
            double yaw = obs.yaw ? obs.yaw.doubleValue : 0;
            double roll = obs.roll ? obs.roll.doubleValue : 0;
            if (fabs(yaw) < 0.35 && fabs(roll) < 0.35) {
                facing = YES;
            }
        } else {
            // 低版本先按“检测到人脸”作为兜底
            facing = YES;
        }
    }

    self.lastCallbackTs = now;

    if (hasFace) {
        NSString *msg = facing ? @"检测到人脸，且基本正对屏幕" : @"检测到人脸，但未正对屏幕";
        [self emitInfoHasFace:YES facing:facing faces:faces message:msg];
    } else {
        [self emitInfoHasFace:NO facing:NO faces:@[] message:@"未识别到人脸，请正对屏幕"];
    }
}

- (void)emitInfoHasFace:(BOOL)hasFace
                 facing:(BOOL)facing
                  faces:(NSArray *)faces
                message:(NSString *)message {
    if (!self.keepAliveCallback) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.keepAliveCallback(@{
            @"code": @0,
            @"hasFace": @(hasFace),
            @"isFacingScreen": @(facing),
            @"faces": faces ?: @[],
            @"message": message ?: @"",
            @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000))
        }, YES);
    });
}

- (void)emitError:(NSString *)message {
    if (!self.keepAliveCallback) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.keepAliveCallback(@{
            @"code": @-1,
            @"hasFace": @NO,
            @"isFacingScreen": @NO,
            @"faces": @[],
            @"message": message ?: @"未知错误",
            @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000))
        }, YES);
    });
}

@end
