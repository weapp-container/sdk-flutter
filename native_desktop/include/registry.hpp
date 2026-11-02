#pragma once
#include "nlohmann/json.hpp"
#include "weapp_container_sdk.h"
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace weapp::flutter {
using Json = nlohmann::json;
struct Status {
  std::string code, message;
  explicit operator bool() const { return code.empty(); }
  static Status error(std::string code, std::string message) {
    return {std::move(code), std::move(message)};
  }
};
using Reply = std::function<void(Status, Json)>;
struct Buffer {
  weapp_container_sdk_buffer value{};
  ~Buffer() { weapp_container_sdk_buffer_free(&value); }
  Status read(int32_t result, Json *out = nullptr);
};
Status command(weapp_container_sdk_session *, const char *,
               const Json & = Json::object(), Json * = nullptr);
// Flutter client-window geometry is translated exactly once by its native
// platform adapter. Content/event coordinates remain local to the GPU surface.
inline void translate_chrome(Json &payload, double dx, double dy) {
  if (!std::isfinite(dx) || !std::isfinite(dy))
    throw std::invalid_argument("native screen origin must be finite");
  for (auto name : {"contentRect", "menuButtonRect"}) {
    auto &rect = payload.at(name);
    for (auto edge : {"left", "right"})
      if (rect.contains(edge))
        rect[edge] = rect.at(edge).get<double>() + dx;
    for (auto edge : {"top", "bottom"})
      if (rect.contains(edge))
        rect[edge] = rect.at(edge).get<double>() + dy;
  }
}
struct PresentationStamp {
  uint64_t generation = 0, revision = 0;
  Json layout = nullptr;
  bool operator==(const PresentationStamp &other) const {
    return generation == other.generation && revision == other.revision && layout == other.layout;
  }
};
// Raster/GPU callbacks only record immutable receipts. Session commands remain
// on the Registry owner thread; an epoch invalidates detached/reloaded
// textures.
class PresentationFeedback {
public:
  struct Ticket {
    uint64_t epoch = 0, sequence = 0;
    PresentationStamp stamp;
  };
  Ticket submitted(PresentationStamp stamp) {
    std::lock_guard<std::mutex> lock(mutex_);
    return {epoch_, ++submitted_, stamp};
  }
  void consumed(const Ticket &ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (ticket.epoch != epoch_ || ticket.sequence <= consumed_)
      return;
    consumed_ = ticket.sequence;
    pending_ = ticket.stamp;
  }
  std::optional<PresentationStamp> take() {
    std::lock_guard<std::mutex> lock(mutex_);
    return std::exchange(pending_, std::nullopt);
  }
  void invalidate() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++epoch_;
    pending_.reset();
    consumed_ = submitted_;
  }

private:
  std::mutex mutex_;
  uint64_t epoch_ = 1, submitted_ = 0, consumed_ = 0;
  std::optional<PresentationStamp> pending_;
};
struct Frame {
  const weapp_container_sdk_frame *handle = nullptr;
  weapp_container_sdk_frame_info_data info{};
  std::shared_ptr<PresentationFeedback> feedback;
  PresentationFeedback::Ticket presentation;
  ~Frame();
  static std::shared_ptr<const Frame>
  acquire(weapp_container_sdk_session *, Status &, PresentationStamp,
          std::shared_ptr<PresentationFeedback>);
};
// A raster callback takes a shared immutable lease; producer publication never
// invalidates pixels already borrowed by the engine.
class Mailbox {
public:
  void publish(std::shared_ptr<const Frame> f) {
    std::lock_guard<std::mutex> l(mutex_);
    frame_ = std::move(f);
  }
  std::shared_ptr<const Frame> read() {
    std::lock_guard<std::mutex> l(mutex_);
    return frame_;
  }

private:
  std::mutex mutex_;
  std::shared_ptr<const Frame> frame_;
};
struct Metrics {
  Json value;
  uint32_t width = 0, height = 0;
  double preview_x = 0, preview_y = 0;
  static Status parse(const Json &, Metrics &);
};
class Texture {
public:
  virtual ~Texture() = default;
  virtual int64_t texture_id() const = 0;
  virtual Status layout(const Metrics &) { return {}; }
  virtual Status set_visible(bool) { return {}; }
  virtual bool is_native_preview() const { return false; }
  virtual Status set_chrome(const Json &, std::function<void(Json)>) {
    return Status::error("ERR_UNSUPPORTED_CAPABILITY",
                         "native chrome is unavailable for this surface");
  }
  virtual Status suspend(weapp_container_sdk_session *) { return {}; }
  virtual Status resume(weapp_container_sdk_session *) { return {}; }
  virtual Status present(weapp_container_sdk_session *, const Metrics &,
                         PresentationStamp) = 0;
  std::optional<PresentationStamp> take_presented() {
    return feedback_->take();
  }
  void invalidate_presentation() { feedback_->invalidate(); }
  // Completion is always delivered on the platform owner thread. Each platform
  // keeps its callback object alive until its registrar releases it.
  virtual void retire(std::function<void(Status)> completion) = 0;

protected:
  std::shared_ptr<PresentationFeedback> feedback_ =
      std::make_shared<PresentationFeedback>();
};
// OS adapters are injected so the registry lifecycle tests use the public C
// transport without linking a platform desktop library.
class NativeDeviceApis {
public:
  virtual ~NativeDeviceApis() = default;
  virtual Json configuration() const = 0;
  virtual bool dispatch(const Json &) = 0;
  virtual Status pump() = 0;
  virtual Status retire() = 0;
  virtual Status set_foreground(bool) = 0;
  virtual Status update_components(const Json &) = 0;
};
using DeviceCommand = std::function<Status(const std::string &, const Json &, Json *)>;
using DeviceFactory = std::function<std::unique_ptr<NativeDeviceApis>(
    const Json &, const Json &, const std::string &, DeviceCommand, Status &)>;
class Registry {
public:
  using Factory = std::function<std::shared_ptr<Texture>(
      Status &, std::function<void(Status)>)>;
  using Emit = std::function<void(Json)>;
  // Schedule owns a callback on the platform thread until it returns true.
  // It survives the engine/plugin to retry resource cleanup safely.
  using Schedule = std::function<void(std::function<bool()>)>;
  using Log = std::function<void(Status)>;
  Registry(std::string platform, std::string storage_root, Factory, Emit,
           Schedule, Log);
  ~Registry();
  // Optional native child preview; no CPU texture is selected when required.
  void set_gpu_preview_factory(Factory factory) {
    gpu_factory_ = std::move(factory);
  }
  void set_device_api_factory(DeviceFactory factory) { device_factory_ = std::move(factory); }
  void invoke(const std::string &, const Json &, Reply);
  void tick();
  void shutdown();

private:
  struct Entry {
    int64_t id = 0;
    Json config;
    Metrics metrics;
    std::set<std::string> methods;
    weapp_container_sdk_session *native = nullptr;
    std::shared_ptr<Texture> texture;
    bool closing = false, closed = false, retiring = false, foreground = true,
         occluded = false, host_layout_observed = false;
    Json host_chrome, native_chrome, host_surface;
    std::string account_cleanup;
    bool account_native_cleanup = false, account_cleanup_waiting = false;
    Json device_options = nullptr;
    std::unique_ptr<NativeDeviceApis> devices;
    std::set<std::string> device_snapshot_names;
    std::string device_session;
    Json load;
    Reply pending_load;
    std::vector<Reply> pending_prepares;
    std::map<uint64_t, std::vector<Reply>> flushes;
    std::vector<Reply> closes;
    Status close_status;
    ~Entry();
  };
  struct Life {
    Registry *owner = nullptr;
  };
  std::shared_ptr<Life> life_;
  std::string platform_, root_, epoch_, next_epoch_;
  Factory factory_, gpu_factory_;
  DeviceFactory device_factory_;
  Emit emit_;
  Schedule schedule_;
  Log log_;
  int64_t next_id_ = 1;
  bool ticking_ = false, stopped_ = false;
  std::map<int64_t, std::shared_ptr<Entry>> sessions_;
  std::vector<Reply> initializers_;
  static bool cleanup(const std::shared_ptr<Entry> &, const Log &);
  Status ensure(Entry &);
  Status prepare_devices(Entry &, bool register_live = false);
  static Status retire_devices(Entry &);
  Status refresh_device_owner(Entry &, const Json &);
  Status observe_layout(Entry &, const Metrics &);
  Status foreground(Entry &);
  void load(Entry &, const Json &, Reply);
  void detach(const std::shared_ptr<Entry> &, Reply);
  void close(const std::shared_ptr<Entry> &, Reply);
  void finish_close(const std::shared_ptr<Entry> &);
  void settle_epoch();
  Status prepare_account_cleanup(const std::shared_ptr<Entry> &);
  void drain(const std::shared_ptr<Entry> &);
  void report(int64_t, Status);
};
} // namespace weapp::flutter
