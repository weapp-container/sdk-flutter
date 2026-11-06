#import "WeappContainerMacosPlugin.h"
#include "registry.hpp"
#include "native_device_apis.hpp"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <mutex>
using namespace weapp::flutter;

namespace {
std::string fromString(NSString *value) {
  return std::string([value UTF8String],
                     [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}
NSString *toString(const std::string &value) {
  return [[NSString alloc] initWithBytes:value.data()
                                  length:value.size()
                                encoding:NSUTF8StringEncoding];
}
Json fromObject(id value) {
  if (!value || value == [NSNull null])
    return nullptr;
  if ([value isKindOfClass:NSString.class])
    return fromString(value);
  if ([value isKindOfClass:NSNumber.class]) {
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
      return bool([value boolValue]);
    const char *type = [value objCType];
    if (!strcmp(type, @encode(float)) || !strcmp(type, @encode(double)))
      return [value doubleValue];
    return int64_t([value longLongValue]);
  }
  if ([value isKindOfClass:NSArray.class]) {
    Json a = Json::array();
    for (id item in value)
      a.push_back(fromObject(item));
    return a;
  }
  if ([value isKindOfClass:NSDictionary.class]) {
    Json a = Json::object();
    for (id key in value) {
      if (![key isKindOfClass:NSString.class])
        throw std::invalid_argument("map keys must be strings");
      a[fromString(key)] = fromObject(value[key]);
    }
    return a;
  }
  throw std::invalid_argument("unsupported channel value");
}
id toObject(const Json &value) {
  if (value.is_null())
    return NSNull.null;
  if (value.is_boolean())
    return @(value.get<bool>());
  if (value.is_number_integer())
    return @(value.get<int64_t>());
  if (value.is_number())
    return @(value.get<double>());
  if (value.is_string())
    return toString(value.get_ref<const std::string &>());
  if (value.is_array()) {
    NSMutableArray *a = [NSMutableArray array];
    for (auto &item : value)
      [a addObject:toObject(item)];
    return a;
  }
  NSMutableDictionary *a = [NSMutableDictionary dictionary];
  for (auto i = value.begin(); i != value.end(); ++i)
    a[toString(i.key())] = toObject(i.value());
  return a;
}
struct PixelStore {
  std::mutex mutex;
  CVPixelBufferRef published = nullptr;
  uint64_t generation = 0, revision = UINT64_MAX;
  bool busy = false, retired = false;
  ~PixelStore() {
    if (published)
      CVPixelBufferRelease(published);
  }
  CVPixelBufferRef copy() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!published) return nullptr;
    auto buffer = CVPixelBufferRetain(published);
    if (feedback) feedback->consumed(presentation);
    return buffer;
  }
  std::shared_ptr<PresentationFeedback> feedback;
  PresentationFeedback::Ticket presentation;
  void publish(CVPixelBufferRef buffer, std::shared_ptr<PresentationFeedback> owner,
               PresentationFeedback::Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex);
    if (published)
      CVPixelBufferRelease(published);
    published = CVPixelBufferRetain(buffer);
    feedback = std::move(owner);
    presentation = ticket;
  }
};
struct Target {
  CVPixelBufferRef pixel = nullptr;
  CVMetalTextureRef view = nullptr;
  id<MTLTexture> texture;
  ~Target() {
    if (view)
      CFRelease(view);
    if (pixel)
      CVPixelBufferRelease(pixel);
  }
};
} // namespace
@interface WCFlutterPixelBuffer : NSObject <FlutterTexture> {
@public
  std::shared_ptr<PixelStore> pixels;
  std::function<void()> unregistered;
}
@end
@implementation WCFlutterPixelBuffer
- (CVPixelBufferRef)copyPixelBuffer {
  return pixels->copy();
}
- (void)dealloc {
  // macOS Flutter currently releases its external-texture wrapper without
  // calling the optional iOS unregister notification. Final object release is
  // the ownership boundary on both implementations, including in-flight
  // readers.
  auto done = std::move(unregistered);
  if (done)
    dispatch_async(dispatch_get_main_queue(), ^{
      done();
    });
}
@end

namespace {
class MacTexture final : public Texture,
                         public std::enable_shared_from_this<MacTexture> {
public:
  MacTexture(id<FlutterTextureRegistry> registrar,
             std::function<void(Status)> error)
      : registrar_(registrar), error_(std::move(error)),
        state_(std::make_shared<PixelStore>()) {}
  ~MacTexture() override {
    if (cache_)
      CFRelease(cache_);
  }
  Status initialize() {
    device_ = MTLCreateSystemDefaultDevice();
    queue_ = [device_ newCommandQueue];
    if (!device_ || !queue_)
      return Status::error(
          "ERR_METAL_UNAVAILABLE",
          "macOS Flutter requires a Metal device and command queue");
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device_,
                                  nullptr, &cache_) != kCVReturnSuccess)
      return Status::error("ERR_METAL",
                           "could not create the CVMetalTexture cache");
    texture_ = [WCFlutterPixelBuffer new];
    texture_->pixels = state_;
    id_ = [registrar_ registerTexture:texture_];
    return id_ > 0 ? Status{}
                   : Status::error("ERR_TEXTURE",
                                   "Flutter refused texture registration");
  }
  int64_t texture_id() const override { return id_; }
  Status resume(weapp_container_sdk_session *native) override {
    if (attached_)
      return {};
    Buffer b;
    auto s = b.read(weapp_container_sdk_metal_attach(
        native, (__bridge void *)device_, (__bridge void *)queue_, &b.value));
    if (s) {
      attached_ = true;
      state_->revision = UINT64_MAX;
    }
    return s;
  }
  Status suspend(weapp_container_sdk_session *native) override {
    if (!attached_)
      return {};
    ++state_->generation;
    // Every native present has a preallocated, submitted completion buffer on
    // the same queue. Reuse that fence: retirement must not depend on a fresh
    // allocation while the GPU is under memory pressure.
    [last_ waitUntilCompleted];
    Buffer b;
    auto s = b.read(weapp_container_sdk_metal_detach(native, &b.value));
    if (s) {
      attached_ = false;
      state_->revision = UINT64_MAX;
      state_->busy = false;
    }
    return s;
  }
  Status present(weapp_container_sdk_session *native, const Metrics &metrics,
                 PresentationStamp stamp) override {
    const auto revision = stamp.revision;
    if (!attached_ || state_->retired || state_->busy ||
        (state_->revision == revision && width_ == metrics.width &&
         height_ == metrics.height))
      return {};
    auto target = std::make_shared<Target>();
    NSDictionary *attrs = @{
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, metrics.width, metrics.height,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs,
                            &target->pixel) != kCVReturnSuccess)
      return Status::error("ERR_METAL",
                           "could not allocate IOSurface pixel buffer");
    NSDictionary *textureAttrs = @{
      (id)kCVMetalTextureUsage :
          @(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)
    };
    if (CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache_, target->pixel,
            (__bridge CFDictionaryRef)textureAttrs, MTLPixelFormatBGRA8Unorm,
            metrics.width, metrics.height, 0,
            &target->view) != kCVReturnSuccess)
      return Status::error("ERR_METAL",
                           "could not create IOSurface Metal texture");
    target->texture = CVMetalTextureGetTexture(target->view);
    id<MTLCommandBuffer> completion = [queue_ commandBuffer];
    if (!completion)
      return Status::error("ERR_METAL",
                           "could not allocate GPU completion buffer");
    Buffer b;
    auto feedback = feedback_;
    auto ticket = feedback->submitted(stamp);
    auto result = b.read(weapp_container_sdk_metal_present(
        native, (__bridge void *)target->texture, metrics.width, metrics.height,
        &b.value));
    auto state = state_;
    auto generation = state->generation;
    auto error = error_;
    __weak id<FlutterTextureRegistry> registry = registrar_;
    auto textureId = id_;
    auto width = metrics.width, height = metrics.height;
    state->busy = true;
    auto weak = weak_from_this();
    [completion addCompletedHandler:^(id<MTLCommandBuffer> finished) {
      bool success =
          result && finished.status == MTLCommandBufferStatusCompleted;
      NSString *description =
          finished.error.localizedDescription ?: @"Metal submission failed";
      dispatch_async(dispatch_get_main_queue(), ^{
        if (state->generation != generation || state->retired)
          return;
        state->busy = false;
        if (!success) {
          if (result)
            error(Status::error("ERR_METAL", description.UTF8String));
          return;
        }
        state->publish(target->pixel, feedback, ticket);
        state->revision = revision;
        if (auto self = weak.lock()) {
          self->width_ = width;
          self->height_ = height;
        }
        [registry textureFrameAvailable:textureId];
      });
    }];
    [completion commit];
    last_ = completion;
    return result;
  }
  void retire(std::function<void(Status)> done) override {
    state_->retired = true;
    ++state_->generation;
    WCFlutterPixelBuffer *retiring = texture_;
    retiring->unregistered = [done = std::move(done)]() mutable { done({}); };
    texture_ = nil;
    id<FlutterTextureRegistry> registry = registrar_;
    if (registry && id_)
      [registry unregisterTexture:id_];
    // `retiring` releases at scope exit; the completion runs only after Flutter
    // also releases its own reference. No reference cycle points back to it.
  }

private:
  __weak id<FlutterTextureRegistry> registrar_;
  std::function<void(Status)> error_;
  std::shared_ptr<PixelStore> state_;
  WCFlutterPixelBuffer *texture_;
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  id<MTLCommandBuffer> last_;
  CVMetalTextureCacheRef cache_ = nullptr;
  int64_t id_ = 0;
  uint32_t width_ = 0, height_ = 0;
  bool attached_ = false;
};
} // namespace

@implementation WeappContainerMacosPlugin {
  std::unique_ptr<Registry> _registry;
  NSTimer *_timer;
  FlutterEventSink _sink;
  __weak NSView *_hostView;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  WeappContainerMacosPlugin *plugin = [WeappContainerMacosPlugin new];
  plugin->_hostView = registrar.view;
  __weak WeappContainerMacosPlugin *weak = plugin;
  __weak id<FlutterTextureRegistry> textures = registrar.textures;
  NSURL *support = [[NSFileManager defaultManager]
                       URLsForDirectory:NSApplicationSupportDirectory
                              inDomains:NSUserDomainMask]
                       .firstObject;
  NSString *app = NSBundle.mainBundle.bundleIdentifier ?: @"weapp-container";
  NSString *root = [[support URLByAppendingPathComponent:app]
                       URLByAppendingPathComponent:@"WeappContainer"]
                       .path;
  plugin->_registry = std::make_unique<Registry>(
      "macos", root.UTF8String,
      [textures](Status &status, std::function<void(Status)> error)
          -> std::shared_ptr<Texture> {
        auto texture = std::make_shared<MacTexture>(textures, std::move(error));
        status = texture->initialize();
        return status ? texture : nullptr;
      },
      [weak](Json event) {
        WeappContainerMacosPlugin *live = weak;
        if (live && live->_sink)
          live->_sink(toObject(event));
      },
      [](std::function<bool()> retry) {
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.05
                                                repeats:YES
                                                  block:^(NSTimer *timer) {
                                                    if (retry())
                                                      [timer invalidate];
                                                  }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
      },
      [](Status status) {
        NSLog(@"WeApp Container deferred cleanup: %s: %s", status.code.c_str(),
              status.message.c_str());
      });
  plugin->_registry->set_device_api_factory(native_device_api_factory([weak]() -> void * {
    WeappContainerMacosPlugin *live=weak;
    return live ? (__bridge void *)live->_hostView : nullptr;
  }));
  FlutterMethodChannel *methods =
      [FlutterMethodChannel methodChannelWithName:@"dev.weapp.container/methods"
                                  binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:methods];
  FlutterEventChannel *events =
      [FlutterEventChannel eventChannelWithName:@"dev.weapp.container/events"
                                binaryMessenger:registrar.messenger];
  [events setStreamHandler:plugin];
  plugin->_timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                          repeats:YES
                                            block:^(NSTimer *) {
                                              WeappContainerMacosPlugin *live =
                                                  weak;
                                              if (live && live->_registry)
                                                live->_registry->tick();
                                            }];
  [NSRunLoop.mainRunLoop addTimer:plugin->_timer forMode:NSRunLoopCommonModes];
  [registrar publish:plugin];
}
- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  try {
    Json arguments = fromObject(call.arguments);
    NSView *view = _hostView;
    NSWindow *window = view.window;
    NSScreen *screen = window.screen;
    const bool layoutMethod = [call.method isEqualToString:@"hostLayout"] || [call.method isEqualToString:@"prepareHostLayout"];
    const bool chromeMethod = layoutMethod || [call.method isEqualToString:@"hostChrome"] || [call.method isEqualToString:@"prepareHostChrome"];
    const bool clientChrome = chromeMethod && arguments.value("coordinateSpace", "screen") == "flutterClient";
    if (clientChrome && (!view || !window || !screen)) {
      result([FlutterError errorWithCode:@"ERR_NOT_READY" message:@"Chrome needs an attached native host window" details:nil]);
      return;
    }
    if (view && window && screen) {
      NSPoint top = [view convertPoint:NSMakePoint(NSMinX(view.bounds), view.isFlipped ? NSMinY(view.bounds) : NSMaxY(view.bounds)) toView:nil];
      NSPoint inScreen = [window convertPointToScreen:top];
      const double dx = inScreen.x - NSMinX(screen.frame), dy = NSMaxY(screen.frame) - inScreen.y;
      if (clientChrome) {
        arguments.erase("coordinateSpace");
        translate_chrome(layoutMethod ? arguments.at("chrome") : arguments, dx, dy);
      }
      if ([call.method isEqualToString:@"attach"] || [call.method isEqualToString:@"resize"]) {
        arguments["screenTop"] = dy + arguments.value("previewY", 0.0);
      }
    }
    if (chromeMethod) arguments.erase("coordinateSpace");
    _registry->invoke(
        call.method.UTF8String, arguments,
        [result](Status status, Json value) {
          if (status)
            result(value.is_null() ? nil : toObject(value));
          else
            result([FlutterError
                errorWithCode:[NSString
                                  stringWithUTF8String:status.code.c_str()]
                      message:[NSString
                                  stringWithUTF8String:status.message.c_str()]
                      details:nil]);
        });
  } catch (const std::exception &error) {
    result([FlutterError
        errorWithCode:@"ERR_INVALID_ARGUMENT"
              message:[NSString stringWithUTF8String:error.what()]
              details:nil]);
  }
}
- (FlutterError *)onListenWithArguments:(id)arguments
                              eventSink:(FlutterEventSink)sink {
  _sink = sink;
  return nil;
}
- (FlutterError *)onCancelWithArguments:(id)arguments {
  _sink = nil;
  return nil;
}
- (void)dealloc {
  [_timer invalidate];
  _sink = nil;
  _registry.reset();
}
@end
