// Integration harness: real C ABI/QuickJS/Skia/Metal with an instrumented
// FlutterTextureRegistry. The separate Dart integration consumer verifies the
// actual Flutter engine and Texture widget.
#import "../../weapp_container_macos/macos/Classes/WeappContainerMacosPlugin.mm"
#include <chrono>
#include <filesystem>
#include <iostream>

@interface TestTextureRegistry : NSObject <FlutterTextureRegistry> {
@public
  NSMutableDictionary<NSNumber *, NSObject<FlutterTexture> *> *textures;
  int64_t sequence;
  size_t frames;
  CVPixelBufferRef retained;
}
@end
@implementation TestTextureRegistry
- (instancetype)init {
  if ((self = [super init]))
    textures = [NSMutableDictionary dictionary];
  return self;
}
- (int64_t)registerTexture:(NSObject<FlutterTexture> *)texture {
  auto key = ++sequence;
  textures[@(key)] = texture;
  return key;
}
- (void)textureFrameAvailable:(int64_t)textureId {
  NSObject<FlutterTexture> *texture = textures[@(textureId)];
  if (!texture)
    return;
  // Consumer lease is deliberately kept through subsequent render, resize,
  // detach and session destruction; the producer must never mutate its pixels.
  auto pixel = [texture copyPixelBuffer];
  if (pixel) {
    ++frames;
    if (!retained)
      retained = pixel;
    else
      CVPixelBufferRelease(pixel);
  }
}
- (void)unregisterTexture:(int64_t)textureId {
  NSObject<FlutterTexture> *texture = textures[@(textureId)];
  [textures removeObjectForKey:@(textureId)];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    (void)[texture description];
  });
}
- (void)dealloc {
  if (retained)
    CVPixelBufferRelease(retained);
}
@end
static void check(bool value, const char *message) {
  if (!value)
    throw std::runtime_error(message);
}
static void until(Registry &registry, std::function<bool()> done) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (!done()) {
    registry.tick();
    [NSRunLoop.mainRunLoop
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    if (std::chrono::steady_clock::now() > deadline)
      throw std::runtime_error("completion timed out");
  }
}
static Json call(Registry &registry, const std::string &method, Json args,
                 bool success = true) {
  bool done = false;
  Status status;
  Json value;
  registry.invoke(method, args, [&](Status s, Json result) {
    status = s;
    value = result;
    done = true;
  });
  until(registry, [&] { return done; });
  if (bool(status) != success)
    throw std::runtime_error(method + ": " + status.code + " " +
                             status.message);
  return value;
}
static Json metrics(int64_t id, double scale = 1) {
  return {{"id", id},
          {"windowWidth", 320},
          {"windowHeight", 440},
          {"screenWidth", 1280},
          {"screenHeight", 800},
          {"pixelRatio", scale},
          {"statusBarHeight", 0},
          {"screenTop", 0},
          {"deviceOrientation", "landscape"}};
}
int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      check(argc == 3, "pass acceptance pack and isolated storage directory");
      const char unicodeBytes[] = "中文 🧊 \0 tail";
      std::string unicode(unicodeBytes, sizeof(unicodeBytes) - 1);
      Json channel = {{unicode, Json::array({unicode, "", nullptr, true, 7})}};
      check(fromObject(toObject(channel)) == channel,
            "channel codec must preserve Unicode and embedded NULs in values "
            "and keys");
      TestTextureRegistry *textures = [TestTextureRegistry new];
      std::vector<Json> events;
      Registry registry(
          "macos", argv[2],
          [textures](Status &s, std::function<void(Status)> error)
              -> std::shared_ptr<Texture> {
            auto texture = std::make_shared<MacTexture>(textures, error);
            s = texture->initialize();
            return s ? texture : nullptr;
          },
          [&](Json event) { events.push_back(event); },
          [](std::function<bool()> retry) {
            NSTimer *timer = [NSTimer timerWithTimeInterval:0.01
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
                                                        if (retry())
                                                          [timer invalidate];
                                                      }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
          },
          [](Status s) { std::cerr << s.code << ": " << s.message << "\n"; });
      call(registry, "initialize", {{"clientEpoch", "epoch-1"}});
      auto id = call(registry, "create", {{"storageKey", "durable"}})["id"]
                    .get<int64_t>();
      call(registry, "registerHostMethod", {{"id", id}, {"name", "host.echo"}});
      bool loaded = false;
      Status loading;
      registry.invoke(
          "load",
          {{"id", id}, {"packPath", argv[1]}, {"options", Json::object()}},
          [&](Status s, Json) {
            loading = s;
            loaded = true;
          });
      registry.tick();
      check(!loaded, "load must wait for real layout");
      auto textureId =
          call(registry, "attach", metrics(id))["textureId"].get<int64_t>();
      until(registry, [&] { return loaded && textures->frames > 0; });
      check(bool(loading), loading.message.c_str());
      auto capability = call(registry, "capabilities", {{"id", id}});
      check(capability.dump().find("metal") != std::string::npos,
            "actual Metal capability missing");
      check(CVPixelBufferGetWidth(textures->retained) == 320,
            "physical pixel width mismatch");
      CVPixelBufferLockBaseAddress(textures->retained,
                                   kCVPixelBufferLock_ReadOnly);
      auto *first = static_cast<const uint8_t *>(
          CVPixelBufferGetBaseAddress(textures->retained));
      std::vector<uint8_t> snapshot(
          first, first + CVPixelBufferGetDataSize(textures->retained));
      CVPixelBufferUnlockBaseAddress(textures->retained,
                                     kCVPixelBufferLock_ReadOnly);
      call(registry, "load",
           {{"id", id},
            {"packPath", "/does/not/exist"},
            {"options", Json::object()}},
           false);
      check(call(registry, "state", {{"id", id}})["status"] == "ready",
            "failed load lost prior runtime");
      call(registry, "sendMessage",
           {{"id", id},
            {"message", {{"op", "store"}, {"value", "survives-epoch"}}}});
      call(registry, "flushStorage", {{"id", id}});
      call(registry, "resize", metrics(id, 2));
      auto before = textures->frames;
      until(registry, [&] { return textures->frames > before; });
      auto current = [textures->textures[@(textureId)] copyPixelBuffer];
      check(CVPixelBufferGetWidth(current) == 640, "DPR resize mismatch");
      CVPixelBufferRelease(current);
      call(registry, "detach", {{"id", id}});
      check(textures->textures.count == 0, "detach returned before unregister");
      call(registry, "attach", metrics(id, 2));
      call(registry, "setForeground", {{"id", id}, {"foreground", false}});
      call(registry, "sendMessage",
           {{"id", id}, {"message", {{"op", "echo"}, {"value", 123}}}});
      until(registry, [&] {
        for (auto &e : events)
          if (e["event"].value("type", "") == "hostCall")
            return true;
        return false;
      });
      for (auto &e : events)
        if (e["event"].value("type", "") == "hostCall") {
          auto event = e["event"];
          if (event.value("method", "") == "host.echo")
            call(registry, "completeHostCall",
                 {{"id", id}, {"callId", event["callId"]}, {"result", 123}});
        }
      call(registry, "initialize", {{"clientEpoch", "epoch-2"}});
      check(textures->textures.count == 0,
            "epoch changed before textures retired");
      auto reopened =
          call(registry, "create", {{"storageKey", "durable"}})["id"]
              .get<int64_t>();
      check(reopened > id, "epoch reused session id");
      call(registry, "attach", metrics(reopened));
      call(registry, "load",
           {{"id", reopened},
            {"packPath", argv[1]},
            {"options", Json::object()}});
      call(registry, "close", {{"id", reopened}});
      call(registry, "close", {{"id", reopened}});
      CVPixelBufferLockBaseAddress(textures->retained,
                                   kCVPixelBufferLock_ReadOnly);
      check(std::memcmp(snapshot.data(),
                        CVPixelBufferGetBaseAddress(textures->retained),
                        snapshot.size()) == 0,
            "consumer pixel lease mutated after close");
      CVPixelBufferUnlockBaseAddress(textures->retained,
                                     kCVPixelBufferLock_ReadOnly);
      auto pending = call(registry, "create", {{"storageKey", nullptr}})["id"]
                         .get<int64_t>();
      bool cancelled = false;
      registry.invoke("load", {{"id", pending}, {"packPath", argv[1]}},
                      [&](Status s, Json) { cancelled = !s; });
      call(registry, "close", {{"id", pending}});
      check(cancelled, "pending layout load was not cancelled");
      registry.shutdown();
      std::cout
          << "PASS real Metal frame, retained pixel lease, deferred layout, "
             "rollback, DPR, detach, hidden pump, durable close, epoch reset\n";
      return 0;
    } catch (const std::exception &e) {
      std::cerr << "FAIL " << e.what() << "\n";
      return 1;
    }
  }
}
