#import <AVFoundation/AVFoundation.h>

#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXBarCodeScannerProviderInterface.h>
#import <ABI45_0_0EXCamera/ABI45_0_0EXCamera.h>
#import <ABI45_0_0EXCamera/ABI45_0_0EXCameraUtils.h>
#import <ABI45_0_0EXCamera/ABI45_0_0EXCameraManager.h>
#import <ABI45_0_0EXCamera/ABI45_0_0EXCameraCameraPermissionRequester.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXAppLifecycleService.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXUtilities.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXFaceDetectorManagerInterface.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXFaceDetectorManagerProviderInterface.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXFileSystemInterface.h>
#import <ABI45_0_0ExpoModulesCore/ABI45_0_0EXPermissionsInterface.h>

@interface ABI45_0_0EXCamera ()

@property (nonatomic, weak) id<ABI45_0_0EXFileSystemInterface> fileSystem;
@property (nonatomic, weak) ABI45_0_0EXModuleRegistry *moduleRegistry;
@property (nonatomic, strong) id<ABI45_0_0EXFaceDetectorManagerInterface> faceDetectorManager;
@property (nonatomic, strong) id<ABI45_0_0EXBarCodeScannerInterface> barCodeScanner;
@property (nonatomic, weak) id<ABI45_0_0EXPermissionsInterface> permissionsManager;
@property (nonatomic, weak) id<ABI45_0_0EXAppLifecycleService> lifecycleManager;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;
@property (nonatomic, assign) BOOL isValidVideoOptions;

@property (nonatomic, strong) NSDictionary *photoCaptureOptions;
@property (nonatomic, strong) ABI45_0_0EXPromiseResolveBlock photoCapturedResolve;
@property (nonatomic, strong) ABI45_0_0EXPromiseRejectBlock photoCapturedReject;

@property (nonatomic, strong) ABI45_0_0EXPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) ABI45_0_0EXPromiseRejectBlock videoRecordedReject;

@property (nonatomic, copy) ABI45_0_0EXDirectEventBlock onCameraReady;
@property (nonatomic, copy) ABI45_0_0EXDirectEventBlock onMountError;
@property (nonatomic, copy) ABI45_0_0EXDirectEventBlock onPictureSaved;

@property (nonatomic, copy) ABI45_0_0EXDirectEventBlock onBarCodeScanned;
@property (nonatomic, copy) ABI45_0_0EXDirectEventBlock onFacesDetected;

@end

@implementation ABI45_0_0EXCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithModuleRegistry:(ABI45_0_0EXModuleRegistry *)moduleRegistry
{
  if ((self = [super init])) {
    _moduleRegistry = moduleRegistry;
    _session = [AVCaptureSession new];
    _sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
    _faceDetectorManager = [self createFaceDetectorManager];
    _barCodeScanner = [self createBarCodeScanner];
    _lifecycleManager = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI45_0_0EXAppLifecycleService)];
    _fileSystem = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI45_0_0EXFileSystemInterface)];
    _permissionsManager = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI45_0_0EXPermissionsInterface)];
#if !(TARGET_IPHONE_SIMULATOR)
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.needsDisplayOnBoundsChange = YES;
#endif
    _paused = NO;
    _isValidVideoOptions = YES;
    _pictureSize = AVCaptureSessionPresetHigh;
    [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
    [self initializeCaptureSessionInput];
    [self startSession];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [_lifecycleManager registerAppLifecycleListener:self];
  }
  return self;
}

- (void)dealloc
{
  // In very rare case ABI45_0_0EXCamera might be unmounted (and thus deallocated) after starting taking a photo,
  // but still before callbacks from AVCapturePhotoCaptureDelegate are fired (that means before results from taking a photo are handled).
  // This scenario leads to a state when AVCapturePhotoCaptureDelegate is `nil` and
  // neither self.photoCapturedResolve nor self.photoCapturedResolve is called.
  // To prevent hanging promise let's reject here.
  if (_photoCapturedReject) {
    _photoCapturedReject(@"E_IMAGE_CAPTURE_FAILED", @"Camera unmounted during taking photo process.", nil);
  }
}

- (void)onReady:(NSDictionary *)event
{
  if (_onCameraReady) {
    _onCameraReady(nil);
  }
}

- (void)onMountingError:(NSDictionary *)event
{
  if (_onMountError) {
    _onMountError(event);
  }
}

- (void)onBarCodeScanned:(NSDictionary *)event
{
  if (_onBarCodeScanned) {
    _onBarCodeScanned(event);
  }
}

- (void)onPictureSaved:(NSDictionary *)event
{
  if (_onPictureSaved) {
    _onPictureSaved(event);
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _previewLayer.frame = self.bounds;
  [self setBackgroundColor:[UIColor blackColor]];
  [self.layer insertSublayer:_previewLayer atIndex:0];
}

- (void)removeFromSuperview
{
  [_lifecycleManager unregisterAppLifecycleListener:self];
  [self stopSession];
  [super removeFromSuperview];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void)updateType
{
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);
    [self initializeCaptureSessionInput];
    if (!self.session.isRunning) {
      [self startSession];
    }
  });
}

- (void)updateFlashMode
{
  AVCaptureDevice *device = [_videoCaptureDeviceInput device];
  NSError *error = nil;

  if (_flashMode == ABI45_0_0EXCameraFlashModeTorch) {
    if (![device hasTorch]) {
      return;
    }

    if (![device lockForConfiguration:&error]) {
      if (error) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
      }
      return;
    }

    if ([device hasTorch] && [device isTorchModeSupported:AVCaptureTorchModeOn]) {
      if ([device lockForConfiguration:&error]) {
        [device setTorchMode:AVCaptureTorchModeOn];
        [device unlockForConfiguration];
      } else {
        if (error) {
          ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
        }
      }
    }
  } else {
    if (![device hasFlash]) {
      return;
    }

    if (![device lockForConfiguration:&error]) {
      if (error) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
      }
      return;
    }

    if ([device hasFlash])
    {
      if ([device lockForConfiguration:&error]) {
        if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
          [device setTorchMode:AVCaptureTorchModeOff];
        }
        [device unlockForConfiguration];
      } else {
        if (error) {
          ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
        }
      }
    }
  }

  [device unlockForConfiguration];
}

- (void)updateFocusMode
{
  AVCaptureDevice *device = [_videoCaptureDeviceInput device];
  NSError *error = nil;

  if (![device lockForConfiguration:&error]) {
    if (error) {
      ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
    }
    return;
  }

  if ([device isFocusModeSupported:_autoFocus]) {
    if ([device lockForConfiguration:&error]) {
      [device setFocusMode:_autoFocus];
    } else {
      if (error) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
      }
    }
  }

  [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
  AVCaptureDevice *device = [_videoCaptureDeviceInput device];
  NSError *error = nil;

  if (device == nil || device.focusMode != ABI45_0_0EXCameraAutoFocusOff) {
    return;
  }

  if ([device isLockingFocusWithCustomLensPositionSupported]) {
    if (![device lockForConfiguration:&error]) {
      if (error) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
      }
      return;
    }

    ABI45_0_0EX_WEAKIFY(device);
    [device setFocusModeLockedWithLensPosition:_focusDepth completionHandler:^(CMTime syncTime) {
      ABI45_0_0EX_ENSURE_STRONGIFY(device);
      [device unlockForConfiguration];
    }];
    return;
  }

  ABI45_0_0EXLogInfo(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
  return;
}

- (void)updateZoom {
  AVCaptureDevice *device = [_videoCaptureDeviceInput device];
  NSError *error = nil;

  if (![device lockForConfiguration:&error]) {
    if (error) {
      ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
    }
    return;
  }

  device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * _zoom + 1.0;

  [device unlockForConfiguration];
}

- (void)updateWhiteBalance
{
  AVCaptureDevice *device = [_videoCaptureDeviceInput device];
  NSError *error = nil;

  if (![device lockForConfiguration:&error]) {
    if (error) {
      ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
    }
    return;
  }

  if (_whiteBalance == ABI45_0_0EXCameraWhiteBalanceAuto) {
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    [device unlockForConfiguration];
  } else {
    AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
      .temperature = [ABI45_0_0EXCameraUtils temperatureForWhiteBalance:_whiteBalance],
      .tint = 0,
    };
    AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
    if ([device lockForConfiguration:&error]) {
      ABI45_0_0EX_WEAKIFY(device);
      [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
        ABI45_0_0EX_ENSURE_STRONGIFY(device);
        [device unlockForConfiguration];
      }];
    } else {
      if (error) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
      }
    }
  }

  [device unlockForConfiguration];
}

- (void)updatePictureSize
{
  [self updateSessionPreset:_pictureSize];
}

- (void)setIsScanningBarCodes:(BOOL)barCodeScanning
{
  if (_barCodeScanner) {
    [_barCodeScanner setIsEnabled:barCodeScanning];
  } else if (barCodeScanning) {
    ABI45_0_0EXLogError(@"BarCodeScanner module not found. Make sure `expo-barcode-scanner` is installed and linked correctly.");
  }
}

- (void)setBarCodeScannerSettings:(NSDictionary *)settings
{
  if (_barCodeScanner) {
    [_barCodeScanner setSettings:settings];
  }
}

- (void)setIsDetectingFaces:(BOOL)faceDetecting
{
  if (_faceDetectorManager) {
    [_faceDetectorManager setIsEnabled:faceDetecting];
  } else if (faceDetecting) {
    ABI45_0_0EXLogError(@"FaceDetector module not found. Make sure `expo-face-detector` is installed and linked correctly.");
  }
}

- (void)updateFaceDetectorSettings:(NSDictionary *)settings
{
  if (_faceDetectorManager) {
    [_faceDetectorManager updateSettings:settings];
  }
}

- (void)takePicture:(NSDictionary *)options resolve:(ABI45_0_0EXPromiseResolveBlock)resolve reject:(ABI45_0_0EXPromiseRejectBlock)reject
{
  if (_photoCapturedResolve) {
    reject(@"E_ANOTHER_CAPTURE", @"Another photo capture is already being processed. Await the first call.", nil);
    return;
  }
  if (!_photoOutput) {
    reject(@"E_IMAGE_CAPTURE_FAILED", @"Camera is not ready yet. Wait for 'onCameraReady' callback.", nil);
    return;
  }
  AVCaptureConnection *connection = [_photoOutput connectionWithMediaType:AVMediaTypeVideo];
  [connection setVideoOrientation:[ABI45_0_0EXCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];

  _photoCapturedReject = reject;
  _photoCapturedResolve = resolve;
  _photoCaptureOptions = options;

  AVCapturePhotoSettings *outputSettings = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey : AVVideoCodecJPEG}];
  outputSettings.highResolutionPhotoEnabled = YES;
  AVCaptureFlashMode requestedFlashMode = AVCaptureFlashModeOff;
  switch (_flashMode) {
    case ABI45_0_0EXCameraFlashModeOff:
      requestedFlashMode = AVCaptureFlashModeOff;
      break;
    case ABI45_0_0EXCameraFlashModeAuto:
      requestedFlashMode = AVCaptureFlashModeAuto;
      break;
    case ABI45_0_0EXCameraFlashModeOn:
    case ABI45_0_0EXCameraFlashModeTorch:
      requestedFlashMode = AVCaptureFlashModeOn;
      break;
  }
  if ([[_photoOutput supportedFlashModes] containsObject:@(requestedFlashMode)]) {
    outputSettings.flashMode = requestedFlashMode;
  }
  [_photoOutput capturePhotoWithSettings:outputSettings delegate:self];
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer
previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer
     resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
      bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings
                error:(NSError *)error
{
  NSDictionary *options = _photoCaptureOptions;
  ABI45_0_0EXPromiseRejectBlock reject = _photoCapturedReject;
  ABI45_0_0EXPromiseResolveBlock resolve = _photoCapturedResolve;
  _photoCapturedResolve = nil;
  _photoCapturedReject = nil;
  _photoCaptureOptions = nil;

  if (error || !photoSampleBuffer) {
    reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
    return;
  }

  if (!self.fileSystem) {
    reject(@"E_IMAGE_CAPTURE_FAILED", @"No file system module", nil);
    return;
  }

  NSData *imageData = [AVCapturePhotoOutput JPEGPhotoDataRepresentationForJPEGSampleBuffer:photoSampleBuffer previewPhotoSampleBuffer:previewPhotoSampleBuffer];
  
  CGImageSourceRef sourceCGIImageRef = CGImageSourceCreateWithData((CFDataRef) imageData, NULL);
  NSDictionary *sourceMetadata = (__bridge NSDictionary *) CGImageSourceCopyPropertiesAtIndex(sourceCGIImageRef, 0, NULL);
  [self handleCapturedImageData:imageData metadata:sourceMetadata options:options resolver:resolve reject:reject];
  CFRelease(sourceCGIImageRef);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error 
{
  NSDictionary *options = _photoCaptureOptions;
  ABI45_0_0EXPromiseRejectBlock reject = _photoCapturedReject;
  ABI45_0_0EXPromiseResolveBlock resolve = _photoCapturedResolve;
  _photoCapturedResolve = nil;
  _photoCapturedReject = nil;
  _photoCaptureOptions = nil;

  if (error || !photo) {
    reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
    return;
  }

  if (!self.fileSystem) {
    reject(@"E_IMAGE_CAPTURE_FAILED", @"No file system module", nil);
    return;
  }

  NSData *imageData = [photo fileDataRepresentation];
  [self handleCapturedImageData:imageData metadata:photo.metadata options:options resolver:resolve reject:reject];
}

- (void)handleCapturedImageData:(NSData *)imageData metadata:(NSDictionary *)metadata options:(NSDictionary *)options resolver:(ABI45_0_0EXPromiseResolveBlock)resolve reject:(ABI45_0_0EXPromiseRejectBlock)reject
{
  UIImage *takenImage = [UIImage imageWithData:imageData];
  BOOL useFastMode = [options[@"fastMode"] boolValue];
  if (useFastMode) {
    resolve(nil);
  }

  CGSize previewSize;
  if (UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation])) {
    previewSize = CGSizeMake(self.previewLayer.frame.size.height, self.previewLayer.frame.size.width);
  } else {
    previewSize = CGSizeMake(self.previewLayer.frame.size.width, self.previewLayer.frame.size.height);
  }
  
  CGImageRef takenCGImage = takenImage.CGImage;
  CGRect cropRect = CGRectMake(0, 0, CGImageGetWidth(takenCGImage), CGImageGetHeight(takenCGImage));
  CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, cropRect);
  takenImage = [ABI45_0_0EXCameraUtils cropImage:takenImage toRect:croppedSize];

  NSString *path = [self.fileSystem generatePathInDirectory:[self.fileSystem.cachesDirectory stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
  float width = takenImage.size.width;
  float height = takenImage.size.height;
  NSData *processedImageData = nil;
  float quality = [options[@"quality"] floatValue];

  NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
  if ([options[@"exif"] boolValue]) {
    NSMutableDictionary *updatedExif = [ABI45_0_0EXCameraUtils updateExifMetadata:metadata[(NSString *)kCGImagePropertyExifDictionary] withAdditionalData:@{ @"Orientation": @([ABI45_0_0EXCameraUtils exportImageOrientation:takenImage.imageOrientation]) }];
    updatedExif[(NSString *)kCGImagePropertyExifPixelYDimension] = @(width);
    updatedExif[(NSString *)kCGImagePropertyExifPixelXDimension] = @(height);
    response[@"exif"] = updatedExif;
    
    NSMutableDictionary *updatedMetadata = [metadata mutableCopy];
    updatedMetadata[(NSString *)kCGImagePropertyExifDictionary] = updatedExif;
    
    // UIImage does not contain metadata information. We need to add them to CGImage manually.
    processedImageData = [ABI45_0_0EXCameraUtils dataFromImage:takenImage withMetadata:updatedMetadata imageQuality:quality];
  } else {
    processedImageData = UIImageJPEGRepresentation(takenImage, quality);
  }
  
  if (!processedImageData) {
    return reject(@"E_IMAGE_SAVE_FAILED", @"Could not save the image.", nil);
  }
  
  response[@"uri"] = [ABI45_0_0EXCameraUtils writeImage:processedImageData toPath:path];
  response[@"width"] = @(width);
  response[@"height"] = @(height);

  if ([options[@"base64"] boolValue]) {
    response[@"base64"] = [processedImageData base64EncodedStringWithOptions:0];
  }

  if ([options[@"fastMode"] boolValue]) {
    [self onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
  } else {
    resolve(response);
  }
}

- (void)record:(NSDictionary *)options resolve:(ABI45_0_0EXPromiseResolveBlock)resolve reject:(ABI45_0_0EXPromiseRejectBlock)reject
{
  if (_movieFileOutput == nil) {
    // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
    // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
    // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
    if (_faceDetectorManager) {
      [_faceDetectorManager stopFaceDetection];
    }
    [self setupMovieFileCapture];
  }

  if (_movieFileOutput != nil && !_movieFileOutput.isRecording && _videoRecordedResolve == nil && _videoRecordedReject == nil) {
    bool shouldBeMuted = options[@"mute"] && [options[@"mute"] boolValue];
    [self updateSessionAudioIsMuted:shouldBeMuted];

    AVCaptureConnection *connection = [_movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    // TODO: Add support for videoStabilizationMode (right now it is not only read, never written to)
    if (connection.isVideoStabilizationSupported == NO) {
      ABI45_0_0EXLogWarn(@"%s: Video Stabilization is not supported on this device.", __func__);
    } else {
      [connection setPreferredVideoStabilizationMode:self.videoStabilizationMode];
    }
    [connection setVideoOrientation:[ABI45_0_0EXCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];
    
    AVCaptureSessionPreset preset;
    if (options[@"quality"]) {
      ABI45_0_0EXCameraVideoResolution resolution = [options[@"quality"] integerValue];
      preset = [ABI45_0_0EXCameraUtils captureSessionPresetForVideoResolution:resolution];
    } else if ([self.session.sessionPreset isEqual:AVCaptureSessionPresetPhoto]) {
      preset = AVCaptureSessionPresetHigh;
    }

    if (preset != nil) {
      [self updateSessionPreset:preset];
    }
    
    [self setVideoOptions:options forConnection:connection onReject:reject];
    
    bool canBeMirrored = connection.isVideoMirroringSupported;
    bool shouldBeMirrored = options[@"mirror"] && [options[@"mirror"] boolValue];
    if (canBeMirrored && shouldBeMirrored) {
      [connection setVideoMirrored:shouldBeMirrored];
    }

    ABI45_0_0EX_WEAKIFY(self);
    dispatch_async(self.sessionQueue, ^{
      ABI45_0_0EX_STRONGIFY(self);
      // it is possible that the session has been invalidated at this point
      // for example, the video codec option is invalid and so this call has already rejected
      if (!self.isValidVideoOptions) {
        return;
      }

      if (!self) {
        reject(@"E_IMAGE_SAVE_FAILED", @"Camera view has been unmounted.", nil);
        return;
      }
      if (!self.fileSystem) {
        reject(@"E_IMAGE_SAVE_FAILED", @"No file system module", nil);
        return;
      }
      NSString *directory = [self.fileSystem.cachesDirectory stringByAppendingPathComponent:@"Camera"];
      NSString *path = [self.fileSystem generatePathInDirectory:directory withExtension:@".mov"];
      NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
      [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
      self.videoRecordedResolve = resolve;
      self.videoRecordedReject = reject;
    });
  }
}

// Video options are set in an async block to prevent the possible race condition outlined here:
// https://github.com/react-native-camera/react-native-camera/pull/2694
- (void)setVideoOptions:(NSDictionary *)options forConnection:(AVCaptureConnection *)connection onReject:(ABI45_0_0EXPromiseRejectBlock)reject
{
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_STRONGIFY(self);
    // Reset validation flag
    self.isValidVideoOptions = YES;

    if (options[@"maxDuration"]) {
      Float64 maxDuration = [options[@"maxDuration"] floatValue];
      self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }

    if (options[@"maxFileSize"]) {
      self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }
    
    if (options[@"codec"]) {
      AVVideoCodecType videoCodecType = [ABI45_0_0EXCameraUtils videoCodecForType: [options[@"codec"] integerValue]];

      if ([self.movieFileOutput.availableVideoCodecTypes containsObject:videoCodecType]) {
        [self.movieFileOutput setOutputSettings: @{AVVideoCodecKey: videoCodecType} forConnection: connection];
        self.videoCodecType = videoCodecType;
      } else {
        if ([videoCodecType isEqualToString: @"VIDEO_CODEC_UNKNOWN"]) {
          videoCodecType = options[@"codec"];
        }
        NSString *videoCodecErrorMessage = [NSString stringWithFormat: @"Video Codec '%@' is not supported on this device", videoCodecType];
        reject(@"E_RECORDING_FAILED", videoCodecErrorMessage, nil);
        
        [self cleanupMovieFileCapture];
        self.videoRecordedResolve = nil;
        self.videoRecordedReject = nil;
        self.isValidVideoOptions = NO;
      }
    }
    
  });
}

- (void)maybeStartFaceDetection:(BOOL)mirrored {
  if (self.faceDetectorManager) {
    AVCaptureConnection *connection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:[ABI45_0_0EXCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];
    [self.faceDetectorManager maybeStartFaceDetectionOnSession:self.session withPreviewLayer:self.previewLayer mirrored:mirrored];
  }
}

- (void)setPresetCamera:(NSInteger)presetCamera
{
  _presetCamera = presetCamera;
  [self.faceDetectorManager updateMirrored:_presetCamera!=1];
}

- (void)stopRecording
{
  [_movieFileOutput stopRecording];
}

- (void)resumePreview
{
  [[_previewLayer connection] setEnabled:YES];
}

- (void)pausePreview
{
  [[_previewLayer connection] setEnabled:NO];
}

- (void)startSession
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
#if TARGET_IPHONE_SIMULATOR
  return;
#endif
  if (![_permissionsManager hasGrantedPermissionUsingRequesterClass:[ABI45_0_0EXCameraCameraPermissionRequester class]]) {
    [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    return;
  }
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);

    if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
      return;
    }

    AVCapturePhotoOutput *photoOutput = [AVCapturePhotoOutput new];
    photoOutput.highResolutionCaptureEnabled = YES;
    photoOutput.livePhotoCaptureEnabled = NO;
    if ([self.session canAddOutput:photoOutput]) {
      [self.session addOutput:photoOutput];
      self.photoOutput = photoOutput;
    }

    [self setRuntimeErrorHandlingObserver:
     [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
      ABI45_0_0EX_ENSURE_STRONGIFY(self);
      dispatch_async(self.sessionQueue, ^{
        ABI45_0_0EX_ENSURE_STRONGIFY(self)
        // Manually restarting the session since it must
        // have been stopped due to an error.
        [self.session startRunning];
        [self ensureSessionConfiguration];
        [self onReady:nil];
      });
    }]];

    // when BarCodeScanner is enabled since the beginning of camera component lifecycle,
    // some race condition occurs in reconfiguration and barcodes aren't scanned at all
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_USEC), self.sessionQueue, ^{
      ABI45_0_0EX_ENSURE_STRONGIFY(self);
      [self maybeStartFaceDetection:self.presetCamera!=1];
      if (self.barCodeScanner) {
        [self.barCodeScanner maybeStartBarCodeScanning];
      }

      [self.session startRunning];
      [self ensureSessionConfiguration];
      [self onReady:nil];
    });
  });
#pragma clang diagnostic pop
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
  return;
#endif
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);

    if (self.faceDetectorManager) {
      [self.faceDetectorManager stopFaceDetection];
    }
    if (self.barCodeScanner) {
      [self.barCodeScanner stopBarCodeScanning];
    }
    [self.previewLayer removeFromSuperlayer];
    [self.session commitConfiguration];
    [self.session stopRunning];
    for (AVCaptureInput *input in self.session.inputs) {
      [self.session removeInput:input];
    }

    for (AVCaptureOutput *output in self.session.outputs) {
      [self.session removeOutput:output];
    }
  });
}

- (void)initializeCaptureSessionInput
{
  if (_videoCaptureDeviceInput.device.position == _presetCamera) {
    return;
  }

  __block UIInterfaceOrientation interfaceOrientation;
  [ABI45_0_0EXUtilities performSynchronouslyOnMainThread:^{
    interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
  }];
  AVCaptureVideoOrientation orientation = [ABI45_0_0EXCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];

  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);

    [self.session beginConfiguration];

    NSError *error = nil;
    AVCaptureDevice *captureDevice = [ABI45_0_0EXCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];
    AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];

    if (error || captureDeviceInput == nil) {
      NSString *errorMessage = @"Camera could not be started - ";
      if (error) {
        errorMessage = [errorMessage stringByAppendingString:[error description]];
      } else {
        errorMessage = [errorMessage stringByAppendingString:@"there's no captureDeviceInput available"];
      }
      [self onMountingError:@{@"message": errorMessage}];
      return;
    }

    [self.session removeInput:self.videoCaptureDeviceInput];
    if ([self.session canAddInput:captureDeviceInput]) {
      [self.session addInput:captureDeviceInput];

      self.videoCaptureDeviceInput = captureDeviceInput;
      [self updateZoom];
      [self updateFocusMode];
      [self updateFocusDepth];
      [self updateWhiteBalance];
      [self.previewLayer.connection setVideoOrientation:orientation];
    }

    [self.session commitConfiguration];
  });
}

// Some configuration need to be applied on session after it's started
// - torchMode: https://stackoverflow.com/a/53666293/4337317
- (void)ensureSessionConfiguration
{
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);
    [self updateFlashMode];
  });
}

#pragma mark - internal

- (void)updateSessionPreset:(AVCaptureSessionPreset)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
  if (preset) {
    ABI45_0_0EX_WEAKIFY(self);
    dispatch_async(_sessionQueue, ^{
      ABI45_0_0EX_ENSURE_STRONGIFY(self);
      [self.session beginConfiguration];
      if ([self.session canSetSessionPreset:preset]) {
        self.session.sessionPreset = preset;
      }
      [self.session commitConfiguration];
    });
  }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
  ABI45_0_0EX_WEAKIFY(self);
  dispatch_async(_sessionQueue, ^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);
    [self.session beginConfiguration];

    for (AVCaptureDeviceInput* input in [self.session inputs]) {
      if ([input.device hasMediaType:AVMediaTypeAudio]) {
        if (isMuted) {
          [self.session removeInput:input];
        }
        [self.session commitConfiguration];
        return;
      }
    }

    if (!isMuted) {
      NSError *error = nil;

      AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
      AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];

      if (error || audioDeviceInput == nil) {
        ABI45_0_0EXLogInfo(@"%s: %@", __func__, error);
        return;
      }

      if ([self.session canAddInput:audioDeviceInput]) {
        [self.session addInput:audioDeviceInput];
      }
    }

    [self.session commitConfiguration];
  });
}

- (void)onAppForegrounded
{
  if (![_session isRunning] && [self isSessionPaused]) {
    _paused = NO;
    ABI45_0_0EX_WEAKIFY(self);
    dispatch_async(_sessionQueue, ^{
      ABI45_0_0EX_ENSURE_STRONGIFY(self);
      [self.session startRunning];
      [self ensureSessionConfiguration];
    });
  }
}

- (void)onAppBackgrounded
{
  if ([_session isRunning] && ![self isSessionPaused]) {
    _paused = YES;
    ABI45_0_0EX_WEAKIFY(self);
    dispatch_async(_sessionQueue, ^{
      ABI45_0_0EX_ENSURE_STRONGIFY(self);
      [self.session stopRunning];
    });
  }
}

- (void)orientationChanged:(NSNotification *)notification
{
  UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
  [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation
{
  ABI45_0_0EX_WEAKIFY(self);
  AVCaptureVideoOrientation videoOrientation = [ABI45_0_0EXCameraUtils videoOrientationForInterfaceOrientation:orientation];
  [ABI45_0_0EXUtilities performSynchronouslyOnMainThread:^{
    ABI45_0_0EX_ENSURE_STRONGIFY(self);
    if (self.previewLayer.connection.isVideoOrientationSupported) {
      [self.previewLayer.connection setVideoOrientation:videoOrientation];
    }
  }];
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
  AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];

  if ([_session canAddOutput:movieFileOutput]) {
    [_session addOutput:movieFileOutput];
    _movieFileOutput = movieFileOutput;
  }
}

- (void)cleanupMovieFileCapture
{
  if ([_session.outputs containsObject:_movieFileOutput]) {
    [_session removeOutput:_movieFileOutput];
    _movieFileOutput = nil;
  }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
  BOOL success = YES;
  if ([error code] != noErr) {
    NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
    if (value) {
      success = [value boolValue];
    }
  }
  if (success && _videoRecordedResolve != nil) {
    _videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString });
  } else if (_videoRecordedReject != nil) {
    _videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
  }
  _videoRecordedResolve = nil;
  _videoRecordedReject = nil;
  _videoCodecType = nil;

  [self cleanupMovieFileCapture];
  // If face detection has been running prior to recording to file
  // we reenable it here (see comment in -record).
  [self maybeStartFaceDetection:false];

  if (_session.sessionPreset != _pictureSize) {
    [self updateSessionPreset:_pictureSize];
  }
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
  id<ABI45_0_0EXFaceDetectorManagerProviderInterface> faceDetectorProvider = [_moduleRegistry getModuleImplementingProtocol:@protocol(ABI45_0_0EXFaceDetectorManagerProviderInterface)];

  if (faceDetectorProvider) {
    id<ABI45_0_0EXFaceDetectorManagerInterface> faceDetector = [faceDetectorProvider createFaceDetectorManager];
    if (faceDetector) {
      ABI45_0_0EX_WEAKIFY(self);
      [faceDetector setOnFacesDetected:^(NSArray<NSDictionary *> *faces) {
        ABI45_0_0EX_ENSURE_STRONGIFY(self);
        if (self.onFacesDetected) {
          self.onFacesDetected(@{
                                 @"type": @"face",
                                 @"faces": faces
                                 });
        }
      }];
      [faceDetector setSessionQueue:_sessionQueue];
    }
    return faceDetector;
  }
  return nil;
}

# pragma mark - BarCode scanner

- (id)createBarCodeScanner
{
  id<ABI45_0_0EXBarCodeScannerProviderInterface> barCodeScannerProvider = [_moduleRegistry getModuleImplementingProtocol:@protocol(ABI45_0_0EXBarCodeScannerProviderInterface)];
  if (barCodeScannerProvider) {
    id<ABI45_0_0EXBarCodeScannerInterface> barCodeScanner = [barCodeScannerProvider createBarCodeScanner];
    if (barCodeScanner) {
      ABI45_0_0EX_WEAKIFY(self);
      [barCodeScanner setSession:_session];
      [barCodeScanner setSessionQueue:_sessionQueue];
      [barCodeScanner setOnBarCodeScanned:^(NSDictionary *body) {
        ABI45_0_0EX_ENSURE_STRONGIFY(self);
        [self onBarCodeScanned:body];
      }];
    }
    return barCodeScanner;
  }
  return nil;
}

@end
