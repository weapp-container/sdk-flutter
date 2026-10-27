#include "registry.hpp"
#include <cstring>
#include <limits>
#include <utility>

namespace weapp::flutter {
Status Buffer::read(int32_t result, Json *out) {
  try {
    if (!value.data)
      return Status::error("ERR_ABI", "native SDK returned an empty response");
    auto j = Json::parse(value.data, value.data + value.len);
    if (result != WEAPP_CONTAINER_SDK_OK || !j.value("ok", false)) {
      auto e = j.value("error", Json::object());
      return Status::error(e.value("code", "ERR_NATIVE"),
                           e.value("message", "native operation failed"));
    }
    if (out)
      *out = j.value("value", Json());
    return {};
  } catch (const std::exception &e) {
    return Status::error("ERR_ABI", e.what());
  }
}
Status command(weapp_container_sdk_session *s, const char *op, const Json &j,
               Json *out) {
  if (!s)
    return Status::error("ERR_NOT_LOADED",
                         "attach a measured viewport and load a pack first");
  auto bytes = j.dump();
  Buffer b;
  return b.read(weapp_container_sdk_session_command(
                    s, reinterpret_cast<const uint8_t *>(op), std::strlen(op),
                    reinterpret_cast<const uint8_t *>(bytes.data()),
                    bytes.size(), &b.value),
                out);
}
Frame::~Frame() {
  Buffer b;
  if (handle)
    weapp_container_sdk_frame_release(&handle, &b.value);
}
std::shared_ptr<const Frame> Frame::acquire(weapp_container_sdk_session *s,
                                            Status &status, PresentationStamp stamp,
                                            std::shared_ptr<PresentationFeedback> feedback) {
  auto frame = std::make_shared<Frame>();
  Buffer b;
  status =
      b.read(weapp_container_sdk_frame_acquire(s, &frame->handle, &b.value));
  if (!status)
    return {};
  Buffer info;
  status = info.read(
      weapp_container_sdk_frame_info(frame->handle, &frame->info, &info.value));
  if (!status)
    return {};
  if (frame->info.revision != stamp.revision) {
    status = Status::error("ERR_CANCELLED", "Acquired pixels do not match the captured frame revision");
    return {};
  }
  frame->feedback = std::move(feedback);
  frame->presentation = frame->feedback->submitted(stamp);
  return frame;
}
Status Metrics::parse(const Json &a, Metrics &out) {
  try {
    Metrics m;
    m.value = a;
    m.value.erase("id");
    for (auto key : {"windowWidth", "windowHeight", "screenWidth",
                     "screenHeight", "pixelRatio"}) {
      double v = a.at(key).get<double>();
      if (!std::isfinite(v) || v <= 0)
        return Status::error(
            "ERR_INVALID_ARGUMENT",
            "metrics require measured positive dimensions and pixel ratio");
    }
    for (auto key :
         {"windowWidth", "windowHeight", "screenWidth", "screenHeight"}) {
      double dimension = a.at(key).get<double>();
      if (dimension < 0.5 || dimension > std::numeric_limits<uint32_t>::max())
        return Status::error(
            "ERR_INVALID_ARGUMENT",
            "logical dimensions must round to positive 32-bit pixels");
      m.value[key] = uint32_t(std::llround(dimension));
    }
    for (auto key : {"statusBarHeight", "screenTop"}) {
      if (!std::isfinite(a.at(key).get<double>()))
        return Status::error("ERR_INVALID_ARGUMENT", "metrics must be finite");
    }
    if (!a.at("deviceOrientation").is_string())
      return Status::error("ERR_INVALID_ARGUMENT",
                           "deviceOrientation must be a string");
    double width = std::round(a.at("windowWidth").get<double>() *
                              a.at("pixelRatio").get<double>());
    double height = std::round(a.at("windowHeight").get<double>() *
                               a.at("pixelRatio").get<double>());
    if (width < 1 || height < 1 || width > 16384 || height > 16384)
      return Status::error("ERR_INVALID_ARGUMENT",
                           "physical texture size must be between 1 and 16384");
    // Shared SDK viewport dimensions are integral logical pixels.
    m.value["windowWidth"] =
        uint32_t(std::lround(a.at("windowWidth").get<double>()));
    m.value["windowHeight"] =
        uint32_t(std::lround(a.at("windowHeight").get<double>()));
    m.width = uint32_t(std::lround(m.value["windowWidth"].get<double>() *
                                   a.at("pixelRatio").get<double>()));
    m.height = uint32_t(std::lround(m.value["windowHeight"].get<double>() *
                                    a.at("pixelRatio").get<double>()));
    if (!m.value["windowWidth"].get<uint32_t>() ||
        !m.value["windowHeight"].get<uint32_t>())
      return Status::error("ERR_INVALID_ARGUMENT",
                           "logical viewport must round to positive pixels");
    out = std::move(m);
    return {};
  } catch (const std::exception &e) {
    return Status::error("ERR_INVALID_ARGUMENT", e.what());
  }
}
Registry::Entry::~Entry() {
  if (native) {
    Buffer b;
    weapp_container_sdk_session_destroy(&native, &b.value);
  }
}
Registry::Registry(std::string platform, std::string root, Factory f, Emit e,
                   Schedule schedule, Log log)
    : life_(std::make_shared<Life>()), platform_(std::move(platform)),
      root_(std::move(root)), factory_(std::move(f)), emit_(std::move(e)),
      schedule_(std::move(schedule)), log_(std::move(log)) {
  life_->owner = this;
}
Registry::~Registry() {
  shutdown();
  life_->owner = nullptr;
}
void Registry::report(int64_t id, Status status) {
  if (!status && emit_)
    emit_(
        {{"id", id},
         {"event",
          {{"type", "error"},
           {"error", {{"code", status.code}, {"message", status.message}}}}}});
}
Status Registry::ensure(Entry &e) {
  if (e.native)
    return {};
  if (!e.metrics.width)
    return Status::error("ERR_NOT_LAID_OUT",
                         "initial measured viewport is required");
  Json display = e.metrics.value;
  display.erase("windowWidth");
  display.erase("windowHeight");
  Json config = e.config;
  config["engine"] = "quickjs";
  config["host"] = {{"kind", "desktop"},
                    {"platform", platform_},
                    {"windowWidth", e.metrics.value["windowWidth"]},
                    {"windowHeight", e.metrics.value["windowHeight"]},
                    {"displayMetrics", display}};
  auto bytes = config.dump();
  Buffer b;
  auto result = b.read(weapp_container_sdk_session_new(
      reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), &e.native,
      &b.value));
  if (!result)
    return result;
  for (auto &method : e.methods)
    if (auto s = command(e.native, "registerHostMethod", {{"name", method}});
        !s)
      return s;
  return {};
}
Status Registry::foreground(Entry &e) {
  if (!e.native || e.closing || e.closed)
    return {};
  Json state;
  auto s = command(e.native, "state", Json::object(), &state);
  if (!s || state.value("status", "") != "ready")
    return s;
  bool visible = e.foreground && bool(e.texture) && !e.retiring;
  return state.value("foreground", false) == visible
             ? Status{}
             : command(e.native, "lifecycle",
                       {{"event", visible ? "show" : "hide"}});
}
void Registry::load(Entry &e, const Json &a, Reply reply) {
  if (!e.metrics.width) {
    if (e.pending_load) {
      reply(Status::error("ERR_BUSY", "a load is already waiting for layout"),
            {});
      return;
    }
    e.load = a;
    e.pending_load = std::move(reply);
    return;
  }
  auto s = ensure(e);
  if (s && e.texture) {
    e.texture->invalidate_presentation();
    s = e.texture->suspend(e.native);
  }
  if (s) {
    s = command(e.native, "load", a);
    Json state;
    auto observed = command(e.native, "state", Json::object(), &state);
    if (observed && state.value("status", "") == "ready") {
      auto visible = foreground(e);
      if (s && !visible)
        s = visible;
      if (e.texture) {
        auto resumed = e.texture->resume(e.native);
        if (s && !resumed)
          s = resumed;
      }
    }
  }
  reply(s, nullptr);
}
void Registry::detach(const std::shared_ptr<Entry> &e, Reply reply) {
  if (e->retiring) {
    reply(Status::error("ERR_BUSY", "texture retirement is pending"), {});
    return;
  }
  if (!e->texture) {
    reply({}, nullptr);
    return;
  }
  e->texture->invalidate_presentation();
  auto s = e->texture->suspend(e->native);
  if (!s) {
    reply(s, {});
    return;
  }
  e->retiring = true;
  report(e->id, foreground(*e));
  auto weak = std::weak_ptr<Life>(life_);
  e->texture->retire(
      [weak, e, reply = std::move(reply)](Status status) mutable {
        if (status)
          e->texture.reset();
        e->retiring = false;
        if (auto life = weak.lock(); life && life->owner) {
          reply(status, nullptr);
          if (!status) {
            e->closing = false;
            auto replies = std::exchange(e->closes, {});
            for (auto &r : replies)
              r(status, {});
          } else
            life->owner->finish_close(e);
        }
      });
}
void Registry::close(const std::shared_ptr<Entry> &e, Reply reply) {
  if (e->closed && !e->retiring && !e->native) {
    reply(e->close_status, nullptr);
    return;
  }
  e->closes.push_back(std::move(reply));
  if (e->closing)
    return;
  if (e->pending_load) {
    auto pending = std::exchange(e->pending_load, {});
    pending(
        Status::error("ERR_CANCELLED", "session closed before initial layout"),
        {});
  }
  if (e->texture && !e->retiring) {
    e->texture->invalidate_presentation();
    auto s = e->texture->suspend(e->native);
    if (!s) {
      auto replies = std::exchange(e->closes, {});
      for (auto &r : replies)
        r(s, {});
      return;
    }
  }
  e->closing = true;
  e->close_status = {};
  Json result;
  auto s = e->native ? command(e->native, "close", Json::object(), &result)
                     : Status{};
  if (!s) {
    e->closing = false;
    auto replies = std::exchange(e->closes, {});
    for (auto &r : replies)
      r(s, {});
    return;
  }
  if (!e->native || !result.value("pending", false))
    e->closed = true;
  if (e->texture) {
    if (!e->retiring)
      detach(e, [](Status, Json) {});
    return;
  }
  finish_close(e);
}
void Registry::finish_close(const std::shared_ptr<Entry> &e) {
  if (!e->closing || !e->closed || e->texture || e->retiring)
    return;
  if (e->native) {
    Buffer b;
    auto s = b.read(weapp_container_sdk_session_destroy(&e->native, &b.value));
    if (!s) {
      e->close_status = s;
      e->closing = false;
      auto replies = std::exchange(e->closes, {});
      for (auto &r : replies)
        r(s, {});
      return;
    }
  }
  auto replies = std::exchange(e->closes, {});
  for (auto &r : replies)
    r(e->close_status, nullptr);
  settle_epoch();
}
void Registry::settle_epoch() {
  if (initializers_.empty())
    return;
  for (auto &[id, e] : sessions_)
    if (!e->closed || e->native || e->texture || e->retiring)
      return;
  Status result;
  for (auto &[id, e] : sessions_)
    if (!e->close_status) {
      result = e->close_status;
      break;
    }
  sessions_.clear();
  epoch_ = std::move(next_epoch_);
  next_epoch_.clear();
  auto replies = std::exchange(initializers_, {});
  for (auto &r : replies)
    r(result, nullptr);
}
void Registry::drain(const std::shared_ptr<Entry> &e) {
  if (!e->native)
    return;
  Json events;
  auto s = command(e->native, "takeEvents", Json::object(), &events);
  if (!s) {
    report(e->id, s);
    return;
  }
  for (auto &event : events) {
    auto type = event.value("type", "");
    if (type == "storageFlushed") {
      auto ticket = event.value("ticket", uint64_t(0));
      auto found = e->flushes.find(ticket);
      if (found != e->flushes.end()) {
        Status status;
        if (!event.value("ok", true)) {
          auto error = event.value("error", Json::object());
          status =
              Status::error(error.value("code", "ERR_STORAGE"),
                            error.value("message", "storage flush failed"));
        }
        auto replies = std::move(found->second);
        e->flushes.erase(found);
        for (auto &reply : replies)
          reply(status, nullptr);
      }
    }
    if (type == "closed") {
      e->closed = true;
      if (!event.value("ok", true)) {
        auto error = event.value("error", Json::object());
        e->close_status =
            Status::error(error.value("code", "ERR_STORAGE"),
                          error.value("message", "close flush failed"));
      }
    }
    if (emit_)
      emit_({{"id", e->id}, {"event", event}});
  }
  finish_close(e);
}
void Registry::tick() {
  if (ticking_ || stopped_)
    return;
  ticking_ = true;
  std::vector<std::shared_ptr<Entry>> entries;
  for (auto &[id, e] : sessions_)
    entries.push_back(e);
  for (auto &e : entries) {
    if (!e->native)
      continue;
    if (e->texture && !e->retiring && e->foreground) {
      auto consumed = e->texture->take_presented();
      if (consumed) {
        Json accepted;
        auto status = command(e->native, "state", Json::object(), &accepted);
        if (status && accepted.value("presentationRequired", false)) {
          status = command(e->native, "presented",
                           {{"generation", consumed->generation},
                            {"revision", consumed->revision}}, &accepted);
          // A newer accepted frame or detached surface intentionally cancels
          // this receipt. Never substitute the newly observed identity.
          if (!status && status.code != "ERR_CANCELLED")
            report(e->id, status);
        } else if (!status) {
          report(e->id, status);
        }
      }
    }
    report(e->id, command(e->native, "pump"));
    Json state;
    if (command(e->native, "state", Json::object(), &state) &&
        state.value("status", "") == "ready" && e->texture && !e->retiring &&
        e->foreground)
      report(e->id,
             e->texture->present(e->native, e->metrics,
             PresentationStamp{state.value("generation", uint64_t(0)),
                               state.value("frameRevision", uint64_t(0))}));
    drain(e);
  }
  ticking_ = false;
}
void Registry::invoke(const std::string &method, const Json &args,
                      Reply reply) {
  try {
    if (stopped_) {
      reply(Status::error("ERR_CLOSED", "Flutter engine is detached"), {});
      return;
    }
    if (!args.is_object()) {
      reply(Status::error("ERR_INVALID_ARGUMENT",
                          "method arguments must be a map"),
            {});
      return;
    }
    if (method == "initialize") {
      auto epoch = args.at("clientEpoch").get<std::string>();
      if (epoch.empty()) {
        reply(Status::error("ERR_INVALID_ARGUMENT",
                            "clientEpoch must not be empty"),
              {});
        return;
      }
      if (initializers_.empty() && epoch == epoch_) {
        reply({}, nullptr);
        return;
      }
      if (!initializers_.empty() && epoch != next_epoch_) {
        reply(Status::error("ERR_BUSY", "another epoch is retiring"), {});
        return;
      }
      next_epoch_ = epoch;
      initializers_.push_back(std::move(reply));
      std::vector<std::shared_ptr<Entry>> entries;
      for (auto &[id, e] : sessions_)
        entries.push_back(e);
      for (auto &e : entries)
        close(e, [this](Status status, Json) {
          if (!status && !initializers_.empty()) {
            auto replies = std::exchange(initializers_, {});
            next_epoch_.clear();
            for (auto &r : replies)
              r(status, {});
          }
        });
      settle_epoch();
      return;
    }
    if (epoch_.empty() || !initializers_.empty()) {
      reply(Status::error("ERR_NOT_INITIALIZED",
                          "initialize this Dart runtime first"),
            {});
      return;
    }
    if (method == "create") {
      auto e = std::make_shared<Entry>();
      e->id = next_id_++;
      e->config = Json::object();
      if (args.contains("storageKey") && !args["storageKey"].is_null()) {
        auto key = args["storageKey"].get<std::string>();
        if (key.empty()) {
          reply(Status::error("ERR_INVALID_ARGUMENT",
                              "storageKey must be nonempty or null"),
                {});
          return;
        }
        e->config["storageKey"] = key;
        e->config["storageRoot"] = root_;
      }
      if (args.contains("sessionId") && !args["sessionId"].is_null())
        e->config["sessionId"] = args["sessionId"].get<std::string>();
      sessions_[e->id] = e;
      reply({}, {{"id", e->id}});
      return;
    }
    auto found = sessions_.find(args.at("id").get<int64_t>());
    if (found == sessions_.end()) {
      reply(
          Status::error("ERR_SESSION_NOT_FOUND", "unknown or retired session"),
          {});
      return;
    }
    auto e = found->second;
    if (method == "close") {
      close(e, std::move(reply));
      return;
    }
    if (e->closing || e->closed) {
      reply(Status::error("ERR_CLOSED", "session is closing or closed"), {});
      return;
    }
    if (method == "detach") {
      detach(e, std::move(reply));
      return;
    }
    if (e->retiring) {
      reply(Status::error("ERR_BUSY", "texture retirement is pending"), {});
      return;
    }
    Json payload = args;
    payload.erase("id");
    if (method == "attach" || method == "resize") {
      Metrics metrics;
      auto s = Metrics::parse(payload, metrics);
      if (!s) {
        reply(s, {});
        return;
      }
      if (method == "attach" && e->texture) {
        reply(Status::error("ERR_ALREADY_ATTACHED",
                            "session already has a texture"),
              {});
        return;
      }
      if (e->native) {
        Json state;
        s = command(e->native, "state", Json::object(), &state);
        if (s && state.value("status", "") == "empty") {
          Buffer buffer;
          s = buffer.read(
              weapp_container_sdk_session_destroy(&e->native, &buffer.value));
        } else if (s)
          s = command(e->native, "windowMetrics", metrics.value);
      }
      // Accepted metrics can precede a user hook error. Keep the authoritative
      // dimensions when the runtime has consumed them.
      if (s)
        e->metrics = metrics;
      else {
        Json state;
        if (command(e->native, "state", Json::object(), &state) &&
            state.contains("viewport") &&
            state["viewport"].value("width", 0u) ==
                metrics.value["windowWidth"] &&
            state["viewport"].value("height", 0u) ==
                metrics.value["windowHeight"])
          e->metrics = metrics;
      }
      if (!s) {
        reply(s, {});
        return;
      }
      if (method == "attach") {
        auto weak = std::weak_ptr<Life>(life_);
        auto id = e->id;
        e->texture = factory_(s, [weak, id](Status error) {
          if (auto life = weak.lock(); life && life->owner)
            life->owner->report(id, error);
        });
        if (!s || !e->texture) {
          reply(s ? Status::error("ERR_TEXTURE", "texture registration failed")
                  : s,
                {});
          return;
        }
        if (e->native) {
          Json state;
          if (command(e->native, "state", Json::object(), &state) &&
              state.value("status", "") == "ready")
            s = e->texture->resume(e->native);
        }
        if (!s) {
          detach(e,
                 [reply = std::move(reply), s](Status retired, Json) mutable {
                   reply(retired ? s : retired, {});
                 });
          return;
        }
        report(e->id, foreground(*e));
        reply({}, {{"textureId", e->texture->texture_id()}});
        if (e->pending_load) {
          auto pending = std::exchange(e->pending_load, {});
          auto pending_args = std::move(e->load);
          load(*e, pending_args, std::move(pending));
        }
      } else
        reply({}, nullptr);
      return;
    }
    if (method == "load") {
      load(*e, payload, std::move(reply));
      return;
    }
    if (method == "registerHostMethod") {
      auto name = args.at("name").get<std::string>();
      if (name.empty() || name.rfind("wx.", 0) == 0) {
        reply(Status::error("ERR_INVALID_ARGUMENT",
                            "host method must be nonempty and cannot use wx.*"),
              {});
        return;
      }
      auto s = e->native ? command(e->native, "registerHostMethod", payload)
                         : Status{};
      if (s)
        e->methods.insert(name);
      reply(s, nullptr);
      return;
    }
    if (method == "setForeground") {
      e->foreground = args.at("foreground").get<bool>();
      reply(foreground(*e), nullptr);
      return;
    }
    if (method == "state" && !e->native) {
      reply({}, {{"status", "empty"},
                 {"foreground", false},
                 {"generation", 0},
                 {"frameRevision", 0}});
      return;
    }
    if (method == "flushStorage" && !e->native) {
      reply({}, nullptr);
      return;
    }
    static const std::set<std::string> allowed = {
        "navigate",         "back",  "sendMessage", "state", "capabilities",
        "completeHostCall", "input", "flushStorage"};
    if (!allowed.count(method)) {
      reply(Status::error("ERR_UNSUPPORTED",
                          "unknown desktop plugin method: " + method),
            {});
      return;
    }
    Json result;
    auto s = command(e->native, method.c_str(), payload, &result);
    if (s && method == "flushStorage" && result.value("pending", false)) {
      e->flushes[result.at("ticket").get<uint64_t>()].push_back(
          std::move(reply));
      return;
    }
    reply(s, method == "state" || method == "capabilities" ? result : Json());
  } catch (const std::exception &error) {
    reply(Status::error("ERR_INVALID_ARGUMENT", error.what()), {});
  }
}
bool Registry::cleanup(const std::shared_ptr<Entry> &e, const Log &log) {
  if (e->retiring)
    return false;
  if (e->texture) {
    e->texture->invalidate_presentation();
    auto status = e->texture->suspend(e->native);
    if (!status) {
      log(status);
      return false;
    }
    e->retiring = true;
    e->texture->retire([e, log](Status status) {
      e->retiring = false;
      if (status)
        e->texture.reset();
      else
        log(status);
    });
    if (e->texture || e->retiring)
      return false;
  }
  if (e->native) {
    Buffer buffer;
    auto status = buffer.read(
        weapp_container_sdk_session_destroy(&e->native, &buffer.value));
    if (!status) {
      log(status);
      return false;
    }
  }
  return true;
}
void Registry::shutdown() {
  if (stopped_)
    return;
  stopped_ = true;
  life_->owner = nullptr;
  Status cancelled = Status::error("ERR_CANCELLED", "Flutter engine detached");
  for (auto &[id, e] : sessions_) {
    if (e->pending_load) {
      auto r = std::exchange(e->pending_load, {});
      r(cancelled, {});
    }
    for (auto &[ticket, replies] : e->flushes)
      for (auto &r : replies)
        r(cancelled, {});
    e->flushes.clear();
    auto replies = std::exchange(e->closes, {});
    for (auto &r : replies)
      r(cancelled, {});
    // Retain every handle and texture if cleanup fails or unregister is still
    // pending. The platform-owned retry task outlives this registry and never
    // invokes a callback into a detached Flutter engine.
    if (!cleanup(e, log_)) {
      auto log = log_;
      schedule_([entry = e, log] { return cleanup(entry, log); });
    }
  }
  sessions_.clear();
  auto replies = std::exchange(initializers_, {});
  for (auto &r : replies)
    r(cancelled, {});
}

} // namespace weapp::flutter
