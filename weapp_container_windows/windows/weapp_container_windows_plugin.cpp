#include "include/weapp_container_windows/weapp_container_windows_plugin.h"
#include "registry.hpp"
#include "native_preview_texture.hpp"
#include <filesystem>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <optional>
#include <shlobj.h>
#include <windows.h>
namespace {
using namespace weapp::flutter;
using Value = flutter::EncodableValue;
Json fromValue(const Value &v) {
  if (std::holds_alternative<std::monostate>(v))
    return nullptr;
  if (auto p = std::get_if<bool>(&v))
    return *p;
  if (auto p = std::get_if<int32_t>(&v))
    return *p;
  if (auto p = std::get_if<int64_t>(&v))
    return *p;
  if (auto p = std::get_if<double>(&v))
    return *p;
  if (auto p = std::get_if<std::string>(&v))
    return *p;
  if (auto p = std::get_if<flutter::EncodableList>(&v)) {
    Json a = Json::array();
    for (auto &item : *p)
      a.push_back(fromValue(item));
    return a;
  }
  if (auto p = std::get_if<flutter::EncodableMap>(&v)) {
    Json a = Json::object();
    for (auto &[k, item] : *p)
      a[std::get<std::string>(k)] = fromValue(item);
    return a;
  }
  throw std::invalid_argument("unsupported channel value");
}
Value toValue(const Json &v) {
  if (v.is_null())
    return Value();
  if (v.is_boolean())
    return Value(v.get<bool>());
  if (v.is_number_integer())
    return Value(v.get<int64_t>());
  if (v.is_number())
    return Value(v.get<double>());
  if (v.is_string())
    return Value(v.get<std::string>());
  if (v.is_array()) {
    flutter::EncodableList a;
    for (auto &item : v)
      a.push_back(toValue(item));
    return Value(a);
  }
  flutter::EncodableMap a;
  for (auto it = v.begin(); it != v.end(); ++it)
    a[Value(it.key())] = toValue(it.value());
  return Value(a);
}
// Message-only window delivers timer and texture retirement on the same thread
// that owns Flutter channels and Rust. It never borrows the host runner HWND.
class Dispatch : public std::enable_shared_from_this<Dispatch> {
public:
  std::function<void()> tick;
  bool initialize() {
    static const wchar_t *name = L"WeappContainerFlutterDispatch";
    WNDCLASSW c{};
    c.lpfnWndProc = proc;
    c.hInstance = GetModuleHandleW(nullptr);
    c.lpszClassName = name;
    RegisterClassW(&c);
    window_ = CreateWindowExW(0, name, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                              nullptr, c.hInstance, this);
    if (!window_)
      return false;
    return SetTimer(window_, 1, 16, nullptr) != 0;
  }
  void post(std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!window_)
      return;
    pending_.push_back(std::move(callback));
    PostMessageW(window_, WM_APP + 17, 0, 0);
  }
  void add_cleanup(std::function<bool()> retry) {
    cleanups_.push_back(std::move(retry));
  }
  void retire() {
    tick = {};
    retiring_ = true;
    keep_ = shared_from_this();
    if (cleanups_.empty())
      stop();
  }
  void run() {
    auto keep = shared_from_this();
    auto callback = tick;
    if (callback)
      callback();
    for (auto it = cleanups_.begin(); it != cleanups_.end();) {
      if ((*it)())
        it = cleanups_.erase(it);
      else
        ++it;
    }
    if (retiring_ && cleanups_.empty())
      stop();
  }
  void stop() {
    HWND old;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      old = window_;
      window_ = nullptr;
      pending_.clear();
    }
    if (old) {
      KillTimer(old, 1);
      DestroyWindow(old);
    }
    tick = {};
    keep_.reset();
  }
  ~Dispatch() { stop(); }

private:
  HWND window_ = nullptr;
  bool retiring_ = false;
  std::shared_ptr<Dispatch> keep_;
  std::vector<std::function<bool()>> cleanups_;
  std::mutex mutex_;
  std::vector<std::function<void()>> pending_;
  static LRESULT CALLBACK proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto self =
        reinterpret_cast<Dispatch *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<Dispatch *>(
          reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(self));
    }
    if (self && message == WM_TIMER) {
      self->run();
      return 0;
    }
    if (self && message == WM_APP + 17) {
      std::vector<std::function<void()>> callbacks;
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        callbacks.swap(self->pending_);
      }
      for (auto &callback : callbacks)
        callback();
      return 0;
    }
    return DefWindowProcW(window, message, w, l);
  }
};
class WinTexture final : public Texture,
                         public std::enable_shared_from_this<WinTexture> {
public:
  WinTexture(flutter::TextureRegistrar *registrar,
             std::shared_ptr<Dispatch> dispatch)
      : registrar_(registrar), dispatch_(std::move(dispatch)),
        texture_(flutter::PixelBufferTexture(
            [this](size_t, size_t) { return copy(); })) {}
  bool initialize() {
    id_ = registrar_->RegisterTexture(&texture_);
    return id_ >= 0;
  }
  int64_t texture_id() const override { return id_; }
  Status present(weapp_container_sdk_session *native, const Metrics &,
                 PresentationStamp stamp) override {
    if (last_stamp_ && stamp == *last_stamp_)
      return {};
    Status status;
    auto frame = Frame::acquire(native, status, stamp, feedback_);
    if (!status)
      return status.code == "ERR_NO_FRAME" ? Status{} : status;
    if (frame->info.stride != frame->info.width * 4)
      return Status::error(
          "ERR_FRAME", "Flutter pixel textures require tightly packed RGBA");
    mailbox_.publish(frame);
    last_stamp_ = stamp;
    return registrar_->MarkTextureFrameAvailable(id_)
               ? Status{}
               : Status::error("ERR_TEXTURE",
                               "Flutter rejected frame notification");
  }
  void retire(std::function<void(Status)> done) override {
    auto self = shared_from_this();
    registrar_->UnregisterTexture(
        id_, [self, done = std::move(done)]() mutable {
          self->dispatch_->post(
              [self, done = std::move(done)]() mutable { done({}); });
        });
  }

private:
  const FlutterDesktopPixelBuffer *copy() {
    auto frame = mailbox_.read();
    if (!frame)
      return nullptr;
    auto lease = new std::shared_ptr<const Frame>(std::move(frame));
    descriptor_.buffer = (*lease)->info.data;
    descriptor_.width = (*lease)->info.width;
    descriptor_.height = (*lease)->info.height;
    descriptor_.release_context = lease;
    descriptor_.release_callback = [](void *p) {
      auto lease = static_cast<std::shared_ptr<const Frame> *>(p);
      // Flutter has finished consuming this immutable pixel buffer.
      (*lease)->feedback->consumed((*lease)->presentation);
      delete lease;
    };
    return &descriptor_;
  }
  flutter::TextureRegistrar *registrar_;
  std::shared_ptr<Dispatch> dispatch_;
  flutter::TextureVariant texture_;
  FlutterDesktopPixelBuffer descriptor_{};
  Mailbox mailbox_;
  int64_t id_ = -1;
  std::optional<PresentationStamp> last_stamp_;
};
std::string storageRoot() {
  PWSTR known = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &known)))
    throw std::runtime_error("LocalAppData is unavailable");
  std::filesystem::path root(known);
  CoTaskMemFree(known);
  wchar_t executable[32768];
  auto size = GetModuleFileNameW(nullptr, executable, 32768);
  if (!size || size == 32768)
    throw std::runtime_error("application path is unavailable");
  auto app = std::filesystem::path(executable).stem();
  return (root / app / L"WeappContainer").u8string();
}
class Plugin final : public flutter::Plugin {
public:
  explicit Plugin(flutter::PluginRegistrarWindows *registrar)
      : dispatch_(std::make_shared<Dispatch>()) {
    if (!dispatch_->initialize())
      throw std::runtime_error(
          "could not create the native owner-thread dispatcher");
    registry_ = std::make_unique<Registry>(
        "windows", storageRoot(),
        [registrar, dispatch = dispatch_](
            Status &status,
            std::function<void(Status)>) -> std::shared_ptr<Texture> {
          auto texture = std::make_shared<WinTexture>(
              registrar->texture_registrar(), dispatch);
          if (!texture->initialize()) {
            status = Status::error("ERR_TEXTURE",
                                   "Flutter refused texture registration");
            return {};
          }
          return texture;
        },
        [this](Json event) {
          if (sink_)
            sink_->Success(toValue(event));
        },
        [dispatch = dispatch_](std::function<bool()> retry) {
          dispatch->add_cleanup(std::move(retry));
        },
        [](Status status) {
          OutputDebugStringA(("WeApp Container deferred cleanup: " +
                              status.code + ": " + status.message + "\n")
                                 .c_str());
        });
    registry_->set_gpu_preview_factory(
        [registrar](Status& status, std::function<void(Status)> errors) -> std::shared_ptr<Texture> {
          auto* view = registrar->GetView();
          auto window = view ? view->GetNativeWindow() : nullptr;
          if (!window || !IsWindow(window)) {
            status = Status::error("ERR_RENDER", "native Flutter window is unavailable");
            return {};
          }
          // The host window owns HWND lifetime. Registry retirement destroys
          // the preview child on this same UI thread before plugin teardown.
          auto parent = std::shared_ptr<void>(window, [](void*) {});
          return std::make_shared<NativePreviewTexture>(std::move(parent), std::move(errors));
        });
    methods_ = std::make_unique<flutter::MethodChannel<Value>>(
        registrar->messenger(), "dev.weapp.container/methods",
        &flutter::StandardMethodCodec::GetInstance());
    methods_->SetMethodCallHandler(
        [this](const flutter::MethodCall<Value> &call,
               std::unique_ptr<flutter::MethodResult<Value>> result) {
          auto shared =
              std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
          try {
            registry_->invoke(call.method_name(),
                              call.arguments() ? fromValue(*call.arguments())
                                               : Json(),
                              [shared](Status status, Json value) {
                                if (status)
                                  shared->Success(toValue(value));
                                else
                                  shared->Error(status.code, status.message);
                              });
          } catch (const std::exception &error) {
            shared->Error("ERR_INVALID_ARGUMENT", error.what());
          }
        });
    events_ = std::make_unique<flutter::EventChannel<Value>>(
        registrar->messenger(), "dev.weapp.container/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<Value>>(
            [this](const Value *,
                   std::unique_ptr<flutter::EventSink<Value>> &&sink)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const Value *)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              sink_.reset();
              return nullptr;
            }));
    dispatch_->tick = [this] { registry_->tick(); };
  }
  ~Plugin() override {
    methods_->SetMethodCallHandler(nullptr);
    events_->SetStreamHandler(nullptr);
    sink_.reset();
    registry_.reset();
    dispatch_->retire();
  }

private:
  std::shared_ptr<Dispatch> dispatch_;
  std::unique_ptr<Registry> registry_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
};
} // namespace
void WeappContainerWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto native = flutter::PluginRegistrarManager::GetInstance()
                    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  try {
    native->AddPlugin(std::make_unique<Plugin>(native));
  } catch (const std::exception &error) {
    OutputDebugStringA(
        (std::string("WeApp Container plugin initialization failed: ") +
         error.what() + "\n")
            .c_str());
  }
}
