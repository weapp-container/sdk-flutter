#include "registry.hpp"
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <thread>
using namespace weapp::flutter;
struct weapp_container_sdk_session {
  bool ready = false, closed = false, input_enabled = false, foreground = true;
  uint64_t generation = 0, revision = 0;
  uint64_t surface_sequence = 9007199254740992ULL, observation_sequence = 9007199254740992ULL, attempt_sequence = 9007199254740992ULL, pack_sequence = 9007199254740992ULL;
  bool atomic = false;
  Json host_surface, pending_layout, accepted_layout, accepted_pack;
  Json events = Json::array(), attempts = Json::object(), host_services = nullptr;
  std::thread::id owner = std::this_thread::get_id();
};
static int destroy_failures = 0, live_sessions = 0;
static int ack_attempts = 0, successful_acks = 0;
static int guest_loads = 0;
static int host_attach_failures = 0, host_observe_failures = 0;
static std::vector<std::pair<std::string, Json>> operations;
static Json native_config;
static weapp_container_sdk_session *last_created_session=nullptr;
static bool presentation_required = false, ack_advances_frame = false;
// Passive responses can be independently corrupted without mutating an SDK
// session, creating an observation or executing a guest in these checks.
static Json passive_state, passive_attempt;
static bool passive_query_failure = false;
static int32_t response(weapp_container_sdk_buffer *out, Json value,
                        bool ok = true, const char *code = "ERR_INJECTED") {
  auto bytes =
      (ok ? Json{{"ok", true}, {"value", value}}
          : Json{{"ok", false},
                 {"error",
                  {{"code", code}, {"message", "injected transient failure"}}}})
          .dump();
  out->len = bytes.size();
  out->data = static_cast<uint8_t *>(std::malloc(out->len));
  std::memcpy(out->data, bytes.data(), out->len);
  return ok ? 0 : -1;
}
extern "C" {
void weapp_container_sdk_buffer_free(weapp_container_sdk_buffer *b) {
  std::free(b->data);
  b->data = nullptr;
  b->len = 0;
}
int32_t weapp_container_sdk_session_new(const uint8_t *config, size_t length,
                                        weapp_container_sdk_session **s,
                                        weapp_container_sdk_buffer *b) {
  native_config = Json::parse(config, config + length);
  *s = new weapp_container_sdk_session;
  last_created_session=*s;
  (*s)->host_services=native_config.value("hostServices",Json());
  (*s)->atomic = native_config.contains("hostLayout");
  ++live_sessions;
  return response(b, nullptr);
}
int32_t weapp_container_sdk_session_command(weapp_container_sdk_session *s,
                                            const uint8_t *operation,
                                            size_t length,
                                            const uint8_t *payload,
                                            size_t payload_length,
                                            weapp_container_sdk_buffer *b) {
  std::string op(reinterpret_cast<const char *>(operation), length);
  operations.emplace_back(op, Json::parse(payload, payload + payload_length));
  assert(s->owner == std::this_thread::get_id());
  const auto arguments = operations.back().second;
  if(op=="configureHostServices"){s->host_services=arguments;return response(b,nullptr);}
  if(op=="hostComponents")return response(b,Json::array());
  if (op == "hostSurface") {
    if (arguments.at("action") == "attach") {
      if (host_attach_failures > 0) { --host_attach_failures; return response(b, nullptr, false, "ERR_TRANSIENT_SURFACE"); }
      s->host_surface = {{"ownerId", "9007199254740993"}, {"surfaceGeneration", std::to_string(++s->surface_sequence)}};
      return response(b, s->host_surface);
    }
    s->host_surface = nullptr;
    s->pending_layout = nullptr;
    return response(b, nullptr);
  }
  if (op == "observeHostLayout") {
    if (host_observe_failures > 0) { --host_observe_failures; return response(b, nullptr, false, "ERR_TRANSIENT_OBSERVATION"); }
    s->pending_layout = {{"schemaVersion", 1}, {"ownerId", arguments.at("ownerId")},
      {"surfaceGeneration", arguments.at("surfaceGeneration")},
      {"observationId", std::to_string(++s->observation_sequence)},
      {"windowMetrics", arguments.at("windowMetrics")}};
    if (s->ready) {
      s->pending_layout["sessionId"] = "runtime-" + std::to_string(s->generation);
      s->pending_layout["pageId"] = s->generation;
    }
    s->events.push_back({{"type", "hostLayoutObservation"}, {"observation", s->pending_layout}});
    return response(b, s->pending_layout);
  }
  if (op == "hostLayout") {
    if (!s->pending_layout.is_object() || arguments.at("observationId") != s->pending_layout.at("observationId"))
      return response(b, nullptr, false, "ERR_CANCELLED");
    s->accepted_layout = arguments;
    s->pending_layout = nullptr;
    return response(b, nullptr);
  }
  if (op == "beginDevPackAttempt") {
    const auto id = std::to_string(++s->attempt_sequence);
    Json receipt = {{"schemaVersion", 1}, {"ownerId", "9007199254740993"}, {"attemptId", id},
      {"status", "prepared"}, {"reloadKind", "restart"}, {"targetRoot", arguments.at("packPath")},
      {"acceptedPackIdentity", s->accepted_pack}};
    s->attempts[id] = receipt;
    return response(b, receipt);
  }
  if (op == "queryDevPackAttempt" && passive_query_failure)
    return response(b, nullptr, false, "ERR_TIMEOUT");
  if (op == "queryDevPackAttempt" && !passive_attempt.is_null())
    return response(b, passive_attempt);
  if (op == "queryDevPackAttempt")
    return response(b, s->attempts.at(arguments.at("attemptId").get<std::string>()));
  if (op == "applyDevPackAttempt") {
    auto &receipt = s->attempts.at(arguments.at("attemptId").get<std::string>());
    if (receipt.at("status") == "prepared") {
      ++guest_loads; s->ready = true; s->foreground = true; ++s->generation; ++s->revision;
      s->input_enabled = !presentation_required;
      s->accepted_pack = {{"root", receipt.at("targetRoot")}, {"acceptedPackRevision", std::to_string(++s->pack_sequence)},
        {"sessionId", "runtime-" + std::to_string(s->generation)}};
      if (arguments.contains("initialHostLayout")) {
        s->accepted_layout = arguments.at("initialHostLayout");
        s->accepted_layout["chrome"]["sessionId"] = s->accepted_pack.at("sessionId");
        s->accepted_layout["chrome"]["pageId"] = s->generation;
        s->pending_layout = nullptr;
      }
      receipt["status"] = "accepted";
      receipt["acceptedPackIdentity"] = s->accepted_pack;
      s->events.push_back({{"type", "devPackAttempt"}, {"receipt", receipt}});
    }
    return response(b, receipt);
  }
  if (op == "classifyDevPack") {
    const auto arguments = Json::parse(payload, payload + payload_length);
    const auto path = arguments.value("packPath", "");
    if (path == "/invalid")
      return response(b, nullptr, false, "ERR_INVALID_MANIFEST");
    return response(b, {{"reloadKind", path == "/style"    ? "inPlace"
                                       : path == "/future" ? "future"
                                                           : "restart"}});
  }
  if (op == "inspectPackChrome")
    return response(b, {{"schemaVersion", 1},
                        {"navigationStyle", "custom"},
                        {"title", "Native"}});
  if (op == "applyDevPack") {
    ++s->revision;
    s->input_enabled = !presentation_required;
    return response(b, {{"reloadKind", "inPlace"},
                        {"state", {{"generation", s->generation}}}});
  }
  if (op == "load") {
    ++guest_loads;
    s->ready = true;
    s->foreground = true;
    ++s->generation;
    ++s->revision;
    s->input_enabled = !presentation_required;
  }
  if (op == "lifecycle") {
    s->foreground = arguments.at("event") == "show";
    return response(b, nullptr);
  }
  if (op == "navigate") {
    ++s->revision;
    s->input_enabled = !presentation_required;
  }
  if (op == "presented") {
    ++ack_attempts;
    auto stamp = Json::parse(payload, payload + payload_length);
    bool stale_layout = false;
    if (s->atomic)
      for (const auto *key : {"ownerId", "surfaceGeneration", "observationId", "layoutRevision"})
        stale_layout = stale_layout || !stamp.contains(key) || stamp.at(key) != s->accepted_layout.at(key);
    if (!presentation_required || stale_layout || stamp["generation"] != s->generation ||
        stamp["revision"] != s->revision)
      return response(b, nullptr, false, "ERR_CANCELLED");
    ++successful_acks;
    s->input_enabled = true;
    if (ack_advances_frame) {
      ack_advances_frame = false;
      ++s->revision;
      s->input_enabled = false;
    }
  }
  if (op == "close") {
    s->closed = true;
    return response(b, {{"pending", false}});
  }
  if (op == "state" && !passive_state.is_null())
    return response(b, passive_state);
  if (op == "state" || op == "presented")
    return response(b, {{"hostSurface", s->host_surface}, {"pendingHostLayout", s->pending_layout},
                        {"acceptedLayout", s->accepted_layout}, {"acceptedPackIdentity", s->accepted_pack},
                        {"chromeGeometryReady", !s->atomic || (s->accepted_layout.is_object() && s->pending_layout.is_null())},
                        {"status", s->closed  ? "closed"
                                   : s->ready ? "ready"
                                              : "empty"},
                        {"presentationEnabled",s->ready&&!s->closed},
                        {"sessionId",s->ready?Json("runtime-"+std::to_string(s->generation)):Json()},
                        {"hostServicesState",s->host_services.is_object()?Json{{"application",s->host_services.at("application")},{"account",s->host_services.at("account")}}:Json()},
                        {"foreground", s->foreground},
                        {"generation", s->generation},
                        {"frameRevision", s->revision},
                        {"presentationRequired", presentation_required},
                        {"inputEnabled", s->input_enabled}});
  if (op == "takeEvents") {
    const auto events = s->events;
    s->events = Json::array();
    return response(b, events);
  }
  if (op == "capabilities") {
    Json caps = {{"hostServices",{{"protocolVersion","1.0"}}},{"pack", {{"devReload", {{"protocolVersion", "1.0"}}}}}};
    caps["chrome"] = {{"nativeMarker", "retained"},
      {"atomicLayout", {{"protocolVersion", "1.0"}}}};
    return response(b, caps);
  }
  return response(b, nullptr);
}
int32_t weapp_container_sdk_session_destroy(weapp_container_sdk_session **s,
                                            weapp_container_sdk_buffer *b) {
  if (destroy_failures > 0) {
    --destroy_failures;
    return response(b, nullptr, false);
  }
  if (*s) {
    delete *s;
    *s = nullptr;
    --live_sessions;
  }
  return response(b, nullptr);
}
int32_t weapp_container_sdk_frame_acquire(weapp_container_sdk_session *,
                                          const weapp_container_sdk_frame **,
                                          weapp_container_sdk_buffer *b) {
  return response(b, nullptr, false);
}
int32_t weapp_container_sdk_frame_info(const weapp_container_sdk_frame *,
                                       weapp_container_sdk_frame_info_data *,
                                       weapp_container_sdk_buffer *b) {
  return response(b, nullptr, false);
}
int32_t weapp_container_sdk_frame_release(const weapp_container_sdk_frame **,
                                          weapp_container_sdk_buffer *b) {
  return response(b, nullptr);
}
}
struct Probe {
  int suspend_failures = 0, retire_failures = 0, live = 0;
  int suspended = 0, resumed = 0, resume_failures = 0;
  std::function<void(Status)> pending;
  bool async = false;
  bool visible = true;
  struct Receipt {
    std::shared_ptr<PresentationFeedback> feedback;
    PresentationFeedback::Ticket ticket;
    void consume() const { feedback->consumed(ticket); }
  };
  std::vector<Receipt> receipts;
};
class TestTexture : public Texture {
public:
  explicit TestTexture(std::shared_ptr<Probe> p, bool native = false)
      : native_(native), p_(std::move(p)) {
    ++p_->live;
  }
  ~TestTexture() override { --p_->live; }
  int64_t texture_id() const override { return native_ ? -1 : 42; }
  bool is_native_preview() const override { return native_; }
  Status set_visible(bool visible) override {
    p_->visible = visible;
    return {};
  }
  Status present(weapp_container_sdk_session *, const Metrics &,
                 PresentationStamp stamp) override {
    if (!last_stamp_ || !(*last_stamp_ == stamp)) {
      p_->receipts.push_back({feedback_, feedback_->submitted(stamp)});
      last_stamp_ = stamp;
    }
    return {};
  }
  Status resume(weapp_container_sdk_session *) override {
    ++p_->resumed;
    if (p_->resume_failures > 0) { --p_->resume_failures; return Status::error("ERR_GPU", "injected GPU resume failure"); }
    return {};
  }
  Status suspend(weapp_container_sdk_session *) override {
    ++p_->suspended;
    if (p_->suspend_failures > 0) {
      --p_->suspend_failures;
      return Status::error("ERR_GPU", "retirement fence unavailable");
    }
    return {};
  }
  void retire(std::function<void(Status)> done) override {
    if (p_->retire_failures > 0) {
      --p_->retire_failures;
      done(Status::error("ERR_TEXTURE", "unregister unavailable"));
    } else if (p_->async)
      p_->pending = std::move(done);
    else
      done({});
  }

private:
  std::optional<PresentationStamp> last_stamp_;
  bool native_;
  std::shared_ptr<Probe> p_;
};
static Json call(Registry &r, const char *method, Json args,
                 bool success = true) {
  bool done = false;
  Status status;
  Json result;
  r.invoke(method, args, [&](Status s, Json value) {
    done = true;
    status = s;
    result = value;
  });
  assert(done);
  assert(bool(status) == success);
  return result;
}
static Status call_status(Registry &r, const char *method, Json args) {
  bool done = false;
  Status status;
  r.invoke(method, args, [&](Status value, Json) { done = true; status = value; });
  assert(done);
  return status;
}
static Json metrics(int64_t id) {
  return {{"id", id},
          {"windowWidth", 320},
          {"windowHeight", 440},
          {"screenWidth", 1280.0},
          {"screenHeight", 800.0},
          {"pixelRatio", 2},
          {"statusBarHeight", 0},
          {"screenTop", 0},
          {"deviceOrientation", "landscape"}};
}
int main() {
  auto probe = std::make_shared<Probe>();
  std::vector<std::function<bool()>> retries;
  std::vector<Status> errors;
  std::vector<Json> forwarded;
  auto make = [&] {
    return std::make_unique<Registry>(
        "macos", "/unused",
        [probe](Status &, std::function<void(Status)>) {
          return std::make_shared<TestTexture>(probe);
        },
        [&](Json event) { forwarded.push_back(std::move(event)); },
        [&](std::function<bool()> retry) {
          retries.push_back(std::move(retry));
        },
        [&](Status s) { errors.push_back(s); });
  };
  auto r = make();
  call(*r, "initialize", {{"clientEpoch", "one"}});
  // Capability preflight must wait for the native view's measured metrics,
  // create an empty runtime with those exact metrics, and execute no guest JS.
  auto prepared_id =
      call(*r, "create", {{"storageKey", nullptr}})["id"].get<int64_t>();
  assert(call(*r, "inspectPackChrome",
              {{"id", prepared_id}, {"packPath", "/verified"}})["title"] ==
         "Native");
  assert(live_sessions == 0 && guest_loads == 0);
  const Json geometry{
      {"schemaVersion", 1},
      {"revision", 1},
      {"contentRect",
       {{"left", 0}, {"top", 48}, {"width", 320}, {"height", 440}}},
      {"menuButtonRect",
       {{"left", 224},
        {"right", 312},
        {"top", 8},
        {"bottom", 40},
        {"width", 88},
        {"height", 32}}}};
  {
    auto window = metrics(prepared_id); window.erase("id");
    const Json observation{{"schemaVersion", 1}, {"ownerId", "3"},
      {"surfaceGeneration", "2"}, {"observationId", "10"}, {"windowMetrics", window}};
    const auto prior_operations = operations.size();
    const auto malformed = call_status(*r, "prepareHostLayout", {{"id", prepared_id},
      {"observation", observation}, {"chrome", geometry}, {"layoutRevision", "20"},
      {"restartAttempt", nullptr}});
    assert(!malformed && malformed.code == "ERR_PROTOCOL_VERSION");
    assert(operations.size() == prior_operations && live_sessions == 0);
  }
  auto geometry_args = geometry;
  geometry_args["id"] = prepared_id;
  auto prospective = geometry;
  translate_chrome(prospective, 12, 24);
  assert(prospective["contentRect"]["left"] == 12 &&
         prospective["contentRect"]["top"] == 72);
  assert(prospective["contentRect"]["width"] == 320 &&
         prospective["menuButtonRect"]["right"] == 324);
  auto prospective_args = prospective;
  prospective_args["id"] = prepared_id;
  const auto before_prepare = operations.size();
  assert(call(*r, "prepareHostChrome", prospective_args) == prospective);
  assert(operations.size() == before_prepare && live_sessions == 0 &&
         guest_loads == 0);
  call(*r, "hostChrome", geometry_args);
  assert(live_sessions == 0 && guest_loads == 0);
  bool prepared = false;
  r->invoke("prepareView", {{"id", prepared_id}},
            [&](Status status, Json result) {
              assert(status &&
                     result["pack"]["devReload"]["protocolVersion"] == "1.0");
              assert(result["chrome"]["atomicLayout"]["preparedRestartMeasurement"] == "1.0");
              assert(result["chrome"]["nativeMarker"] == "retained");
              prepared = true;
            });
  assert(!prepared && live_sessions == 0 && guest_loads == 0);
  call(*r, "attach", metrics(prepared_id));
  assert(prepared && live_sessions == 1 && guest_loads == 0);
  for (const auto *method : {"prepareView", "capabilities"}) {
    const auto caps = call(*r, method, {{"id", prepared_id}});
    assert(caps["chrome"]["atomicLayout"]["preparedRestartMeasurement"] == "1.0");
    assert(caps["chrome"]["atomicLayout"]["protocolVersion"] == "1.0");
    assert(caps["chrome"]["nativeMarker"] == "retained");
  }
  assert(native_config["host"]["windowWidth"] == 320);
  assert(native_config["host"]["windowHeight"] == 440);
  assert(native_config["host"]["displayMetrics"]["pixelRatio"] == 2);
  assert(call(*r, "state", {{"id", prepared_id}})["status"] == "empty");
  call(*r, "load", {{"id", prepared_id}, {"packPath", "/first-measured-load"}});
  assert(guest_loads == 1 && live_sessions == 1);
  auto lifecycle_count = [] {
    return std::count_if(
        operations.begin(), operations.end(),
        [](const auto &operation) { return operation.first == "lifecycle"; });
  };
  const auto before_lifecycle = lifecycle_count();
  call(*r, "setPreviewOccluded", {{"id", prepared_id}, {"occluded", true}});
  assert(!probe->visible);
  const auto receipts = probe->receipts.size();
  r->tick();
  assert(probe->receipts.size() == receipts);
  assert(lifecycle_count() == before_lifecycle &&
         operations.back().first != "lifecycle");
  call(*r, "setPreviewOccluded", {{"id", prepared_id}, {"occluded", false}});
  assert(probe->visible && lifecycle_count() == before_lifecycle);
  auto loaded = std::find_if(
      operations.begin(), operations.end(),
      [](const auto &operation) { return operation.first == "load"; });
  assert(std::any_of(operations.begin(), loaded, [&](const auto &operation) {
    return operation.first == "hostChrome" && operation.second == geometry;
  }));
  call(*r, "close", {{"id", prepared_id}});
  assert(live_sessions == 0 && probe->live == 0);
  // Closing an unmeasured view settles every bounded waiter, without creating
  // a native session or leaving a future waiting for a widget that is gone.
  prepared_id =
      call(*r, "create", {{"storageKey", nullptr}})["id"].get<int64_t>();
  int cancelled_preparations = 0;
  for (int i = 0; i < 8; ++i)
    r->invoke("prepareView", {{"id", prepared_id}}, [&](Status status, Json) {
      assert(!status && status.code == "ERR_CANCELLED");
      ++cancelled_preparations;
    });
  bool bounded_prepare = false;
  r->invoke("prepareView", {{"id", prepared_id}}, [&](Status status, Json) {
    assert(!status && status.code == "ERR_BUSY");
    bounded_prepare = true;
  });
  assert(bounded_prepare && cancelled_preparations == 0 && live_sessions == 0);
  call(*r, "close", {{"id", prepared_id}});
  assert(cancelled_preparations == 8 && live_sessions == 0);
  auto create = [&] {
    auto id =
        call(*r, "create", {{"storageKey", nullptr}})["id"].get<int64_t>();
    call(*r, "attach", metrics(id));
    call(*r, "load", {{"id", id}, {"packPath", "/fake"}});
    return id;
  };
  auto pendingId =
      call(*r, "create", {{"storageKey", nullptr}})["id"].get<int64_t>();
  auto completions = std::make_shared<int>(0);
  r->invoke("load", {{"id", pendingId}, {"packPath", "/fake"}},
            [completions](Status status, Json) {
              assert(status);
              ++*completions;
            });
  call(*r, "attach", metrics(pendingId));
  call(*r, "detach", {{"id", pendingId}});
  call(*r, "attach", metrics(pendingId));
  call(*r, "close", {{"id", pendingId}});
  assert(*completions == 1);
  auto id = create();
  probe->suspend_failures = 1;
  call(*r, "close", {{"id", id}}, false);
  assert(probe->live == 1 && live_sessions == 1);
  probe->async = true;
  bool done = false;
  r->invoke("close", {{"id", id}}, [&](Status s, Json) {
    assert(s);
    done = true;
  });
  assert(!done && probe->pending);
  auto unregister = std::move(probe->pending);
  unregister({});
  assert(done && probe->live == 0 && live_sessions == 0);
  probe->async = false;
  id = create();
  destroy_failures = 1;
  call(*r, "close", {{"id", id}}, false);
  assert(live_sessions == 1);
  call(*r, "close", {{"id", id}});
  assert(live_sessions == 0);
  id = create();
  probe->retire_failures = 1;
  call(*r, "initialize", {{"clientEpoch", "two"}}, false);
  assert(probe->live == 1);
  call(*r, "initialize", {{"clientEpoch", "two"}});
  assert(live_sessions == 0 && probe->live == 0);
  id = create();
  probe->suspend_failures = 1;
  destroy_failures = 1;
  r.reset();
  assert(!retries.empty() && live_sessions == 1 && probe->live == 1 &&
         !errors.empty());
  for (int i = 0; i < 8 && !retries.empty(); ++i)
    for (auto it = retries.begin(); it != retries.end();) {
      if ((*it)())
        it = retries.erase(it);
      else
        ++it;
    }
  assert(retries.empty() && live_sessions == 0 && probe->live == 0);
  // Submission/notification alone cannot make native GPU input ready.
  presentation_required = true;
  r = make();
  call(*r, "initialize", {{"clientEpoch", "presentation"}});
  id = create();
  r->tick();
  assert(ack_attempts == 0 && successful_acks == 0);
  assert(!call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  auto consume = [](Probe::Receipt receipt) {
    std::thread raster([receipt] { receipt.consume(); });
    raster.join();
  };
  auto first = probe->receipts.back();
  consume(first);
  assert(ack_attempts == 0); // Raster thread never enters the runtime.
  r->tick();
  assert(successful_acks == 1);
  assert(call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(first);
  r->tick();
  assert(ack_attempts == 1); // Duplicate reads are bounded and deduplicated.

  call(*r, "navigate", {{"id", id}, {"route", "second"}});
  r->tick();
  auto stale = probe->receipts.back();
  call(*r, "navigate", {{"id", id}, {"route", "third"}});
  r->tick();
  auto current = probe->receipts.back();
  consume(stale);
  r->tick();
  assert(ack_attempts == 2 && successful_acks == 1);
  assert(!call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(current);
  r->tick();
  assert(successful_acks == 2);

  call(*r, "navigate", {{"id", id}, {"route", "ready-hook"}});
  r->tick();
  current = probe->receipts.back();
  ack_advances_frame = true;
  consume(current);
  r->tick();
  assert(successful_acks == 3);
  auto after_ready = probe->receipts.back();
  assert(after_ready.ticket.stamp.revision ==
         current.ticket.stamp.revision + 1);
  assert(!call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(after_ready);
  r->tick();
  assert(successful_acks == 4);

  call(*r, "navigate", {{"id", id}, {"route", "before-reload"}});
  r->tick();
  stale = probe->receipts.back();
  call(*r, "load", {{"id", id}, {"packPath", "/new-generation"}});
  auto attempts = ack_attempts;
  consume(stale);
  r->tick();
  assert(ack_attempts == attempts);
  current = probe->receipts.back();
  assert(current.ticket.stamp.generation == stale.ticket.stamp.generation + 1);
  consume(current);
  r->tick();
  assert(successful_acks == 5);

  // An in-place update must not suspend or replace the native session. It
  // revokes old texture receipts, while restart uses the ordinary load path.
  auto before_dev = call(*r, "state", {{"id", id}});
  auto before_suspend = probe->suspended;
  auto before_resume = probe->resumed;
  assert(call(*r, "classifyDevPack",
              {{"id", id}, {"packPath", "/style"}})["reloadKind"] == "inPlace");
  assert(call(*r, "state", {{"id", id}}) == before_dev);
  stale = probe->receipts.back();
  attempts = ack_attempts;
  auto dev = call(*r, "applyDevPack", {{"id", id}, {"packPath", "/style"}});
  assert(dev["reloadKind"] == "inPlace");
  assert(probe->suspended == before_suspend && probe->resumed == before_resume);
  assert(call(*r, "state", {{"id", id}})["generation"] ==
         before_dev["generation"]);
  consume(stale);
  r->tick();
  assert(ack_attempts == attempts);
  current = probe->receipts.back();
  consume(current);
  r->tick();
  assert(successful_acks == 6);
  before_dev = call(*r, "state", {{"id", id}});
  call(*r, "applyDevPack", {{"id", id}, {"packPath", "/invalid"}}, false);
  call(*r, "applyDevPack", {{"id", id}, {"packPath", "/future"}}, false);
  assert(call(*r, "state", {{"id", id}}) == before_dev);
  assert(probe->suspended == before_suspend && probe->resumed == before_resume);
  dev = call(*r, "applyDevPack", {{"id", id}, {"packPath", "/script"}});
  assert(dev["reloadKind"] == "restart");
  assert(probe->suspended == before_suspend + 1 &&
         probe->resumed == before_resume + 1);
  assert(call(*r, "state", {{"id", id}})["generation"].get<uint64_t>() ==
         before_dev["generation"].get<uint64_t>() + 1);
  r->tick();
  consume(probe->receipts.back());
  r->tick();
  assert(successful_acks == 7);

  call(*r, "navigate", {{"id", id}, {"route", "before-detach"}});
  r->tick();
  stale = probe->receipts.back();
  attempts = ack_attempts;
  call(*r, "detach", {{"id", id}});
  consume(stale);
  r->tick();
  assert(ack_attempts == attempts && successful_acks == 7);
  call(*r, "close", {{"id", id}});

  // Raster-only SDKs keep their established ready semantics and never receive
  // the native-GPU-only command merely because Flutter consumed CPU pixels.
  presentation_required = false;
  attempts = ack_attempts;
  id = create();
  r->tick();
  consume(probe->receipts.back());
  r->tick();
  assert(ack_attempts == attempts && successful_acks == 7);
  call(*r, "close", {{"id", id}});
  r.reset();
  assert(live_sessions == 0 && probe->live == 0);
  // A CPU-only Flutter plugin cannot accept a GPU-required player session.
  for (const auto *platform : {"windows", "linux"}) {
    auto cpu = std::make_unique<Registry>(
        platform, "/unused",
        [probe](Status &, std::function<void(Status)>) {
          return std::make_shared<TestTexture>(probe);
        },
        [](Json) {}, [](std::function<bool()>) {}, [](Status) {});
    call(*cpu, "initialize", {{"clientEpoch", "gpu-boundary"}});
    call(*cpu, "create", {{"storageKey", nullptr}, {"gpuRequired", true}},
         false);
    auto cpu_id = call(*cpu, "create",
                       {{"storageKey", nullptr}, {"gpuRequired", false}})["id"]
                      .get<int64_t>();
    call(*cpu, "close", {{"id", cpu_id}});
    cpu->set_gpu_preview_factory(
        [probe](Status &, std::function<void(Status)>) {
          return std::make_shared<TestTexture>(probe, true);
        });
    auto native_id =
        call(*cpu, "create",
             {{"storageKey", nullptr}, {"gpuRequired", true}})["id"]
            .get<int64_t>();
    auto native_metrics = metrics(native_id);
    native_metrics["previewX"] = 320.0;
    native_metrics["previewY"] = 48.0;
    auto attached = call(*cpu, "attach", native_metrics);
    assert(attached["textureId"] == -1 && attached["nativePreview"] == true);
    Metrics parsed;
    assert(Metrics::parse(native_metrics, parsed));
    assert(parsed.preview_x == 320 && parsed.preview_y == 48);
    assert(!parsed.value.contains("previewX") &&
           !parsed.value.contains("previewY"));
    call(*cpu, "load",
         {{"id", native_id}, {"packPath", "/native-single-session"}});
    assert(live_sessions == 1);
    call(*cpu, "close", {{"id", native_id}});
    assert(live_sessions == 0);
  }
  assert(live_sessions == 0 && probe->live == 0);
  // A failed partial atomic preflight can retry on the same SDK owner. A
  // failed surface attachment never feeds a null identity into observation.
  r = make();
  call(*r, "initialize", {{"clientEpoch", "atomic-setup-retry"}});
  for (const auto failure : {"surface", "observation"}) {
    id = call(*r, "create", {{"storageKey", nullptr},
      {"hostLayout", {{"protocolVersion", "1.0"}, {"atomic", true}}}})["id"].get<int64_t>();
    call(*r, "attach", metrics(id));
    if (std::string(failure) == "surface") host_attach_failures = 1;
    else host_observe_failures = 1;
    Status failed_preflight;
    r->invoke("prepareView", {{"id", id}}, [&](Status status, Json) { failed_preflight = status; });
    assert(!failed_preflight && failed_preflight.code == (std::string(failure) == "surface" ? "ERR_TRANSIENT_SURFACE" : "ERR_TRANSIENT_OBSERVATION"));
    assert(live_sessions == 1);
    call(*r, "prepareView", {{"id", id}});
    assert(live_sessions == 1);
    const auto initial_surface = call(*r, "state", {{"id", id}}).at("hostSurface");
    assert(initial_surface.at("surfaceGeneration") == "9007199254740993");
    call(*r, "detach", {{"id", id}});
    host_attach_failures = 1;
    Status failed_reattach;
    r->invoke("attach", metrics(id), [&](Status status, Json) { failed_reattach = status; });
    assert(!failed_reattach && failed_reattach.code == "ERR_TRANSIENT_SURFACE");
    call(*r, "attach", metrics(id));
    assert(call(*r, "state", {{"id", id}}).at("hostSurface").at("surfaceGeneration") == "9007199254740994");
    call(*r, "close", {{"id", id}});
    assert(live_sessions == 0 && probe->live == 0);
  }
  r.reset();
  // Atomic host layouts retain SDK owner-issued decimal identities through
  // preflight, equal-size observations, attempts and actual texture receipts.
  presentation_required = true;
  r = make();
  call(*r, "initialize", {{"clientEpoch", "atomic-layout"}});
  const auto atomic_begin = operations.size();
  const auto atomic_loads = guest_loads;
  id = call(*r, "create", {{"storageKey", nullptr},
    {"hostLayout", {{"protocolVersion", "1.0"}, {"atomic", true}}}})["id"].get<int64_t>();
  bool atomic_prepared = false;
  r->invoke("prepareView", {{"id", id}}, [&](Status status, Json) { assert(status); atomic_prepared = true; });
  call(*r, "attach", metrics(id));
  assert(atomic_prepared && live_sessions == 1 && guest_loads == atomic_loads);
  assert(native_config["hostLayout"]["atomic"] == true);
  auto atomic_state = call(*r, "state", {{"id", id}});
  auto observation = atomic_state.at("pendingHostLayout");
  assert(observation["ownerId"] == "9007199254740993");
  assert(observation["observationId"] == "9007199254740993");
  auto measured = geometry;
  measured["sessionId"] = "stale-flutter-owner";
  measured["pageId"] = 999;
  measured["observationId"] = "stale-flutter-observation";
  auto complete = call(*r, "prepareHostLayout", {{"id", id}, {"observation", observation},
    {"chrome", measured}, {"layoutRevision", "9007199254740993"}});
  assert(complete.at("windowMetrics") == observation.at("windowMetrics"));
  assert(complete.at("observationId") == observation.at("observationId"));
  assert(!complete.at("chrome").contains("sessionId") && !complete.at("chrome").contains("pageId"));
  assert(!complete.at("chrome").contains("observationId"));
  auto begun = call(*r, "command", {{"id", id}, {"operation", "beginDevPackAttempt"},
    {"payload", {{"operation", "load"}, {"packPath", "/atomic-pack"}, {"expectedAccepted", nullptr}}}});
  assert(begun["attemptId"] == "9007199254740993");
  const Json attempt_identity{{"ownerId", begun.at("ownerId")}, {"attemptId", begun.at("attemptId")}};
  auto submission = attempt_identity;
  submission["expectedAccepted"] = nullptr;
  submission["initialHostLayout"] = complete;
  // A GPU exception after core acceptance must not hide the durable outcome.
  probe->resume_failures = 1;
  call(*r, "command", {{"id", id}, {"operation", "applyDevPackAttempt"}, {"payload", submission}}, false);
  const auto accepted_attempt = call(*r, "command", {{"id", id},
    {"operation", "queryDevPackAttempt"}, {"payload", attempt_identity}});
  assert(accepted_attempt.at("status") == "accepted");
  assert(accepted_attempt.at("acceptedPackIdentity").at("root") == "/atomic-pack");
  assert(accepted_attempt.at("acceptedPackIdentity").at("acceptedPackRevision") == "9007199254740993");
  assert(guest_loads == atomic_loads + 1 && live_sessions == 1);
  assert(call(*r, "command", {{"id", id}, {"operation", "applyDevPackAttempt"},
    {"payload", submission}}) == accepted_attempt);
  assert(guest_loads == atomic_loads + 1);
  r->tick();
  auto atomic_receipt = probe->receipts.back();
  assert(atomic_receipt.ticket.stamp.layout.at("observationId") == complete.at("observationId"));
  const auto atomic_revision = call(*r, "state", {{"id", id}}).at("frameRevision");
  call(*r, "observeHostLayout", {{"id", id}});
  observation = call(*r, "state", {{"id", id}}).at("pendingHostLayout");
  assert(observation.at("windowMetrics") == complete.at("windowMetrics"));
  assert(observation.at("observationId") != complete.at("observationId"));
  assert(call(*r, "state", {{"id", id}}).at("frameRevision") == atomic_revision);
  auto fresh_layout = call(*r, "prepareHostLayout", {{"id", id}, {"observation", observation},
    {"chrome", geometry}, {"layoutRevision", "9007199254740994"}});
  assert(fresh_layout.at("chrome").at("sessionId") == observation.at("sessionId"));
  assert(fresh_layout.at("chrome").at("pageId") == observation.at("pageId"));
  call(*r, "hostLayout", {{"id", id}, {"observation", observation},
    {"chrome", geometry}, {"layoutRevision", "9007199254740994"}});
  r->tick();
  const auto fresh_receipt = probe->receipts.back();
  assert(fresh_receipt.ticket.stamp.revision == atomic_receipt.ticket.stamp.revision);
  assert(!(fresh_receipt.ticket.stamp == atomic_receipt.ticket.stamp));
  const auto before_atomic_acks = successful_acks;
  consume(atomic_receipt); r->tick();
  assert(successful_acks == before_atomic_acks);
  consume(fresh_receipt); r->tick();
  assert(successful_acks == before_atomic_acks + 1);
  const auto &captured_ack = *std::find_if(operations.rbegin(), operations.rend(),
    [](const auto &operation) { return operation.first == "presented"; });
  for (const auto *key : {"ownerId", "surfaceGeneration", "observationId", "layoutRevision"})
    assert(captured_ack.second.at(key) == fresh_layout.at(key));
  assert(std::any_of(forwarded.begin(), forwarded.end(), [](const auto &event) {
    return event.at("event").value("type", "") == "hostLayoutObservation";
  }));
  assert(std::any_of(forwarded.begin(), forwarded.end(), [](const auto &event) {
    return event.at("event").value("type", "") == "devPackAttempt";
  }));
  const auto old_surface = fresh_layout.at("surfaceGeneration");
  call(*r, "detach", {{"id", id}});
  call(*r, "attach", metrics(id));
  observation = call(*r, "state", {{"id", id}}).at("pendingHostLayout");
  assert(observation.at("surfaceGeneration") != old_surface);
  assert(guest_loads == atomic_loads + 1 && live_sessions == 1);
  assert(std::none_of(operations.begin() + atomic_begin, operations.end(), [](const auto &operation) {
    return operation.first == "windowMetrics" || operation.first == "hostChrome";
  }));
  call(*r, "close", {{"id", id}});
  r.reset();
  assert(live_sessions == 0 && probe->live == 0);
  std::cout << "PASS atomic layout tuple, equal-size observation replies, retained owner, exact decimal IDs, durable attempts and GPU failure reconciliation\n";
  // Real host suspension survives acceptance; a developer fault cover only
  // suppresses input/presentation and never fabricates a background lifecycle.
  for (const bool fault_cover : {false, true}) {
    r = make(); call(*r, "initialize", {{"clientEpoch", fault_cover ? "fault-cover" : "suspended-load"}});
    id = call(*r, "create", {{"storageKey", nullptr},
      {"hostLayout", {{"protocolVersion", "1.0"}, {"atomic", true}}}})["id"].get<int64_t>();
    call(*r, "attach", metrics(id)); call(*r, "prepareView", {{"id", id}});
    const auto observed = call(*r, "state", {{"id", id}}).at("pendingHostLayout");
    const auto layout = call(*r, "prepareHostLayout", {{"id", id}, {"observation", observed},
      {"chrome", geometry}, {"layoutRevision", "9007199254740993"}});
    if (fault_cover) call(*r, "setPreviewOccluded", {{"id", id}, {"occluded", true}});
    else call(*r, "setForeground", {{"id", id}, {"foreground", false}});
    const auto before_visibility = lifecycle_count();
    const auto attempt = call(*r, "command", {{"id", id}, {"operation", "beginDevPackAttempt"},
      {"payload", {{"operation", "load"}, {"packPath", "/visibility-pack"}, {"expectedAccepted", nullptr}}}});
    const Json submitted{{"ownerId", attempt.at("ownerId")}, {"attemptId", attempt.at("attemptId")},
      {"expectedAccepted", nullptr}, {"initialHostLayout", layout}};
    call(*r, "command", {{"id", id}, {"operation", "applyDevPackAttempt"}, {"payload", submitted}});
    assert(call(*r, "state", {{"id", id}}).at("foreground") == fault_cover);
    assert(lifecycle_count() == before_visibility + (fault_cover ? 0 : 1));
    call(*r, "close", {{"id", id}}); r.reset();
    assert(live_sessions == 0 && probe->live == 0);
  }
  // A restart proof authorizes preparation only after passive native journal
  // and current-state checks. It never creates/commits a layout or clears a
  // fault. The legacy no-proof behavior is deliberately unchanged.
  {
    r = make(); call(*r, "initialize", {{"clientEpoch", "prepared-restart"}});
    id = call(*r, "create", {{"storageKey", nullptr},
      {"hostLayout", {{"protocolVersion", "1.0"}, {"atomic", true}}}})["id"].get<int64_t>();
    call(*r, "attach", metrics(id)); call(*r, "prepareView", {{"id", id}});
    auto observed = call(*r, "state", {{"id", id}}).at("pendingHostLayout");
    observed["sessionId"] = "current-session"; observed["pageId"] = 1;
    const Json accepted{{"root", std::string(64, 'a')}, {"acceptedPackRevision", "9"}, {"sessionId", "current-session"}};
    const Json proof{{"schemaVersion", 1}, {"ownerId", observed.at("ownerId")},
      {"attemptId", "7"}, {"targetRoot", std::string(64, 'b')}, {"expectedAccepted", accepted}};
    const Json receipt{{"schemaVersion", 1}, {"ownerId", proof.at("ownerId")}, {"attemptId", "7"},
      {"status", "prepared"}, {"operation", "load"}, {"reloadKind", "restart"},
      {"targetRoot", proof.at("targetRoot")}, {"expectedAccepted", accepted}, {"acceptedPackIdentity", accepted}};
    const Json health{{"schemaVersion", 1}, {"requiresRestart", false},
      {"appServiceFault", nullptr}, {"viewFault", nullptr}, {"navigationFault", nullptr}};
    const Json state{{"schemaVersion", 1}, {"status", "ready"}, {"ownerId", observed.at("ownerId")},
      {"hostSurface", {{"ownerId", observed.at("ownerId")}, {"surfaceGeneration", observed.at("surfaceGeneration")}}},
      {"sessionId", "current-session"}, {"page", {{"id", 1}}}, {"pendingHostLayout", observed},
      {"acceptedLayout", nullptr}, {"acceptedPackIdentity", accepted}, {"executionHealth", health},
      {"pendingNavigation", nullptr}, {"inputEnabled", false}, {"presentationEnabled", false}};
    auto faulted = state;
    faulted["executionHealth"]["requiresRestart"] = true;
    faulted["executionHealth"]["viewFault"] = {{"domain", "view"}, {"code", "ERR_TIMEOUT"},
      {"message", "deadline"}, {"requiresRestart", true}};
    auto proof_geometry = geometry;
    proof_geometry["contentRect"]["top"] = observed.at("windowMetrics").at("screenTop");
    const Json request{{"id", id}, {"observation", observed}, {"chrome", proof_geometry},
      {"layoutRevision", "20"}, {"restartAttempt", proof}};
    const auto before_loads = guest_loads;
    std::size_t checked = 0;
    auto check = [&](const Json &arguments, const Json &current, const Json &journal,
                     const char *error = nullptr, const char *method = "prepareHostLayout") {
      passive_state = current; passive_attempt = journal;
      const auto start = operations.size();
      bool done = false;
      r->invoke(method, arguments, [&](Status status, Json result) {
        done = true;
        if (error) assert(!status && status.code == error);
        else {
          assert(status && result.at("observationId") == arguments.at("observation").at("observationId"));
          assert(result.at("windowMetrics") == arguments.at("observation").at("windowMetrics"));
          auto expected_chrome = arguments.at("chrome");
          for (const auto *field : {"sessionId", "pageId", "observationId"}) expected_chrome.erase(field);
          for (const auto *field : {"sessionId", "pageId"})
            if (arguments.at("observation").contains(field)) expected_chrome[field] = arguments.at("observation").at(field);
          assert(result.at("chrome") == expected_chrome);
        }
      });
      assert(done && passive_state == current && passive_attempt == journal);
      for (auto i = start; i < operations.size(); ++i)
        assert(operations[i].first == "queryDevPackAttempt" || operations[i].first == "state");
      if (operations.size() != start) {
        assert(operations[start].first == "queryDevPackAttempt");
        const auto &lookup = arguments.at("restartAttempt");
        assert(operations[start].second == Json({{"ownerId", lookup.at("ownerId")}, {"attemptId", lookup.at("attemptId")}}));
        assert(operations.size() - start == (passive_query_failure ? 1 : 2));
        if (!passive_query_failure)
          assert(operations[start + 1].first == "state" && operations[start + 1].second == Json::object());
      }
      assert(guest_loads == before_loads && live_sessions == 1);
      ++checked;
    };
    for (const auto *operation : {"load", "applyDevPack"}) {
      auto journal = receipt; journal["operation"] = operation;
      check(request, faulted, journal);
      check(request, state, journal);
    }
    for (const auto *field : {"schemaVersion", "ownerId", "attemptId", "targetRoot", "expectedAccepted"}) {
      auto malformed = request; malformed["restartAttempt"].erase(field);
      const auto start = operations.size();
      check(malformed, faulted, receipt, "ERR_PROTOCOL_VERSION");
      assert(operations.size() == start);
    }
    for (const auto &entry : std::vector<std::pair<std::string, Json>>{
      {"schemaVersion", true}, {"ownerId", "03"}, {"ownerId", "18446744073709551616"},
      {"attemptId", 7}, {"targetRoot", std::string(64, 'B')}, {"extra", true},
      {"expectedAccepted", {{"root", std::string(64, 'a')}, {"acceptedPackRevision", "09"}, {"sessionId", "current-session"}}}}) {
      auto malformed = request; malformed["restartAttempt"][entry.first] = entry.second;
      check(malformed, faulted, receipt, "ERR_PROTOCOL_VERSION");
    }
    for (const auto *field : {"root", "acceptedPackRevision", "sessionId"}) {
      auto malformed = request; malformed["restartAttempt"]["expectedAccepted"].erase(field);
      check(malformed, faulted, receipt, "ERR_PROTOCOL_VERSION");
    }
    auto malformed_identity = request;
    malformed_identity["restartAttempt"]["expectedAccepted"]["extra"] = true;
    check(malformed_identity, faulted, receipt, "ERR_PROTOCOL_VERSION");
    for (const auto &context : {Json(), proof}) {
      auto generic = request; generic["restartAttempt"] = context;
      const auto start = operations.size();
      check(generic, faulted, receipt, "ERR_PROTOCOL_VERSION", "hostLayout");
      assert(operations.size() == start);
    }
    for (const auto *status : {"applying", "accepted", "rejected", "cancelled", "notSeen", "notRetained"}) {
      auto journal = receipt; journal["status"] = status;
      check(request, faulted, journal, "ERR_CANCELLED");
    }
    for (const auto &entry : std::vector<std::pair<std::string, Json>>{
      {"schemaVersion", true}, {"ownerId", "4"}, {"attemptId", "8"}, {"targetRoot", std::string(64, 'c')},
      {"operation", "navigate"}, {"reloadKind", "inPlace"}, {"expectedAccepted", nullptr}, {"acceptedPackIdentity", nullptr}}) {
      auto journal = receipt; journal[entry.first] = entry.second;
      check(request, faulted, journal, "ERR_CANCELLED");
    }
    for (const auto *field : {"expectedAccepted", "acceptedPackIdentity"}) {
      auto journal = receipt; journal.erase(field);
      check(request, faulted, journal, "ERR_CANCELLED");
    }
    for (const auto *field : {"root", "acceptedPackRevision", "sessionId"}) {
      auto current = faulted; current["acceptedPackIdentity"][field] = field == std::string("root") ? std::string(64, 'c') : "10";
      check(request, current, receipt, "ERR_CANCELLED");
    }
    auto current = faulted; current["ownerId"] = "4";
    check(request, current, receipt, "ERR_CANCELLED");
    std::vector<Json> invalid;
    for (const auto *field : {"pendingNavigation", "pendingHostLayout", "executionHealth", "sessionId", "page"}) {
      current = faulted; current.erase(field); invalid.push_back(current);
    }
    current = faulted; current["pendingNavigation"] = {{"ticket", "8"}}; invalid.push_back(current);
    current = faulted; current["acceptedLayout"] = observed; current["pendingHostLayout"] = nullptr; invalid.push_back(current);
    current = faulted; current["hostSurface"]["ownerId"] = "4"; invalid.push_back(current);
    current = faulted; current["hostSurface"]["surfaceGeneration"] = "99"; invalid.push_back(current);
    current = faulted; current["sessionId"] = "other"; invalid.push_back(current);
    current = faulted; current["page"]["id"] = 2; invalid.push_back(current);
    for (const auto *field : {"observationId", "ownerId", "surfaceGeneration", "sessionId", "pageId"}) {
      current = faulted; current["pendingHostLayout"][field] = field == std::string("pageId") ? Json(2) : Json("99"); invalid.push_back(current);
    }
    current = faulted; current["pendingHostLayout"]["windowMetrics"]["screenTop"] = 3; invalid.push_back(current);
    for (const auto *field : {"inputEnabled", "presentationEnabled"}) {
      current = faulted; current[field] = true; invalid.push_back(current);
      current = faulted; current.erase(field); invalid.push_back(current);
    }
    for (const auto *field : {"appServiceFault", "navigationFault"}) {
      current = faulted; current["executionHealth"][field] = {{"domain", "appService"}}; invalid.push_back(current);
      current = faulted; current["executionHealth"].erase(field); invalid.push_back(current);
    }
    for (const auto &entry : std::vector<std::pair<std::string, Json>>{
      {"domain", "appService"}, {"requiresRestart", 1}, {"requiresRestart", false}, {"code", "BAD"},
      {"code", "ERR_bad"}, {"message", ""}, {"message", 1}}) {
      current = faulted; current["executionHealth"]["viewFault"][entry.first] = entry.second; invalid.push_back(current);
    }
    current = faulted; current["executionHealth"]["requiresRestart"] = 1; invalid.push_back(current);
    current = faulted; current["executionHealth"]["schemaVersion"] = true; invalid.push_back(current);
    for (const auto &value : invalid) check(request, value, receipt, "ERR_NOT_READY");
    auto stale = request; stale["observation"]["windowMetrics"]["screenTop"] = 3;
    current = faulted; current["pendingHostLayout"] = stale["observation"];
    check(stale, current, receipt, "ERR_NOT_READY");
    for (const auto &entry : std::vector<std::pair<std::string, Json>>{
      {"width", 0}, {"width", 320.51}, {"height", 440.51}, {"top", 0.51},
      {"left", std::numeric_limits<double>::infinity()}, {"height", true}}) {
      auto bad_geometry = request; bad_geometry["chrome"]["contentRect"][entry.first] = entry.second;
      check(bad_geometry, faulted, receipt, "ERR_NOT_READY");
    }
    for (const auto &entry : std::vector<std::pair<std::string, Json>>{
      {"width", 0}, {"right", 313}, {"bottom", 41}, {"left", "224"},
      {"top", std::numeric_limits<double>::quiet_NaN()}}) {
      auto bad_geometry = request; bad_geometry["chrome"]["menuButtonRect"][entry.first] = entry.second;
      check(bad_geometry, faulted, receipt, "ERR_NOT_READY");
    }
    for (const auto *field : {"contentRect", "menuButtonRect"}) {
      auto bad_geometry = request; bad_geometry["chrome"].erase(field);
      check(bad_geometry, faulted, receipt, "ERR_NOT_READY");
    }
    auto subpixel = request;
    subpixel["chrome"]["contentRect"]["width"] = 320.5;
    subpixel["chrome"]["contentRect"]["height"] = 439.5;
    subpixel["chrome"]["contentRect"]["top"] = 0.5;
    // Caller chrome ownership is intentionally replaced from the exact SDK
    // observation, as in Android/iOS; it is never used as authorization.
    subpixel["chrome"]["observationId"] = "stale-caller-value";
    subpixel["chrome"]["sessionId"] = "stale-caller-session";
    subpixel["chrome"]["pageId"] = 999;
    check(subpixel, faulted, receipt);
    auto empty_request = request; empty_request["restartAttempt"]["expectedAccepted"] = nullptr;
    for (const auto *field : {"sessionId", "pageId"}) empty_request["observation"].erase(field);
    auto empty = state; empty["status"] = "empty";
    for (const auto *field : {"executionHealth", "sessionId", "page", "acceptedPackIdentity", "acceptedLayout"}) empty[field] = nullptr;
    empty["pendingHostLayout"] = empty_request["observation"];
    auto empty_receipt = receipt; empty_receipt["expectedAccepted"] = nullptr; empty_receipt["acceptedPackIdentity"] = nullptr;
    check(empty_request, empty, empty_receipt);
    for (const auto *field : {"sessionId", "pageId"}) {
      empty_request["observation"][field] = nullptr; empty["pendingHostLayout"][field] = nullptr;
    }
    check(empty_request, empty, empty_receipt);
    current = faulted; current["acceptedPackIdentity"] = nullptr;
    check(empty_request, current, empty_receipt, "ERR_NOT_READY");
    passive_query_failure = true;
    check(request, faulted, receipt, "ERR_TIMEOUT");
    passive_query_failure = false;
    auto legacy = request; legacy.erase("restartAttempt");
    const auto prior_queries = operations.size();
    check(legacy, faulted, receipt);
    legacy["chrome"]["contentRect"]["width"] = 0;
    check(legacy, faulted, receipt);
    assert(operations.size() == prior_queries);
    passive_state = nullptr; passive_attempt = nullptr;
    call(*r, "close", {{"id", id}}); r.reset();
    assert(live_sessions == 0 && probe->live == 0);
    // A valid proof cannot initialize an unmeasured native owner as a side effect.
    r = make(); call(*r, "initialize", {{"clientEpoch", "proof-no-ensure"}});
    id = call(*r, "create", {{"storageKey", nullptr}})["id"].get<int64_t>();
    auto unmeasured = request; unmeasured["id"] = id;
    const auto before_unmeasured = operations.size();
    const auto absent_owner = call_status(*r, "prepareHostLayout", unmeasured);
    assert(!absent_owner && absent_owner.code == "ERR_NOT_LOADED");
    assert(live_sessions == 0 && operations.size() == before_unmeasured);
    call(*r, "close", {{"id", id}}); r.reset();
    std::cout << "PASS " << checked << " prepared restart proof checks, exact passive journal/CAS/tuple, typed View fault, empty owner and legacy isolation\n";
  }
  // Registry owns the OS driver separately from Dart business callbacks. Every
  // runtime incarnation and account epoch receives a fresh trusted scope.
  {
    struct DeviceProbe {int live=0,retired=0,dispatched=0,pumped=0;std::vector<Json> scopes;};
    class Devices final: public NativeDeviceApis {
      std::shared_ptr<DeviceProbe> probe_;bool retired_=false;
    public:
      explicit Devices(std::shared_ptr<DeviceProbe> probe):probe_(std::move(probe)){++probe_->live;}
      ~Devices(){retire();}
      Json configuration()const override{return {{"apis",Json::array({"wx.getLocation"})},{"syncValues",{{"wx.getAppAuthorizeSetting",{{"locationAuthorized","not determined"}}}}}};}
      bool dispatch(const Json &event)override{if(event.value("method","")=="wx.getLocation"){++probe_->dispatched;return true;}return false;}
      Status pump()override{++probe_->pumped;return {};}
      Status set_foreground(bool)override{return {};}
      Status retire()override{if(!retired_){retired_=true;--probe_->live;++probe_->retired;}return {};}
      Status update_components(const Json &nodes)override{assert(nodes.is_array());return {};}
    };
    auto devices=std::make_shared<DeviceProbe>();
    r=make();r->set_device_api_factory([devices](const Json &trusted,const Json &options,const std::string &root,DeviceCommand,Status &)->std::unique_ptr<NativeDeviceApis>{
      assert(root=="/unused");assert(options.at("allowedNetworkOrigins")==Json::array({"https://api.example.test"}));devices->scopes.push_back(trusted);return std::make_unique<Devices>(devices);
    });
    call(*r,"initialize",{{"clientEpoch","native-devices"}});
    id=call(*r,"create",{{"storageKey",nullptr}}).at("id").get<int64_t>();
    Json trusted={{"application",{{"hostAppId","host"},{"tenantId","tenant"},{"publisherId","publisher"},{"appId","app"},{"environment","release"},{"version","1"},{"packRoot",std::string(64,'a')}}},{"account",{{"principalId","alice"},{"epoch","9007199254740993"}}},{"apis",Json::array()},{"syncValues",Json::object()}};
    auto configure=trusted;configure["id"]=id;call(*r,"configureHostServices",configure);
    call(*r,"installNativeDeviceApis",{{"id",id},{"allowedNetworkOrigins",Json::array({"https://api.example.test"})}});
    assert(devices->live==0);
    call(*r,"attach",metrics(id));call(*r,"load",{{"id",id},{"packPath","/native-devices"}});
    assert(devices->live==1&&devices->retired==1);
    assert(last_created_session->host_services.at("syncValues").contains("wx.getAppAuthorizeSetting"));
    auto *owner=last_created_session;
    owner->events.push_back({{"type","hostCall"},{"callId","native-call"},{"method","wx.getLocation"}});r->tick();
    assert(devices->dispatched==1&&devices->pumped>0);
    const auto before_rebuild=devices->retired;
    call(*r,"load",{{"id",id},{"packPath","/native-devices"}});assert(devices->retired==before_rebuild+1&&devices->live==1);
    Json next_account={{"principalId","bob"},{"epoch","9007199254740994"}};
    owner->host_services["account"]=next_account;
    owner->events.push_back({{"type","accountSwitch"},{"account",next_account},{"syncValues",Json::object()},{"receipt",{{"phase","revoking"},{"operationId","account-op"}}}});r->tick();
    assert(devices->live==0);
    assert(call_status(*r,"completeAccountCleanup",{{"id",id},{"operationId","stale"}}).code=="ERR_ACCOUNT_CLEANUP");
    call(*r,"completeAccountCleanup",{{"id",id},{"operationId","account-op"}});r->tick();
    assert(devices->live==1&&devices->scopes.back().at("account").at("principalId")=="bob");
    assert(devices->scopes.back().at("account").at("epoch")=="9007199254740994");
    call(*r,"close",{{"id",id}});r.reset();assert(devices->live==0&&live_sessions==0);
    std::cout<<"PASS injected native devices, exact epoch, owner replacement, accepted scope, native cleanup handshake and isolated teardown\n";
  }
  PresentationFeedback bounded;
  auto older = bounded.submitted({1, 1}), newer = bounded.submitted({1, 2});
  bounded.consumed(newer);
  bounded.consumed(older);
  assert(bounded.take()->revision == 2 && !bounded.take());
  auto invalidated = bounded.submitted({1, 3});
  bounded.invalidate();
  bounded.consumed(invalidated);
  assert(!bounded.take());
  std::cout << "PASS dev reload classification, in-place receipt revocation, "
               "restart ownership, rejected GPU-only CPU plugins\n";
  std::cout << "PASS measured-view preflight, exact native metrics, no guest "
               "startup, bounded cancellation\n";
  std::cout << "PASS texture-consumption ACK ownership, duplicate/late/epoch "
               "rejection, ready-hook frame mutation, CPU legacy isolation\n";
  std::cout << "PASS close error settlement/retry, unregister ownership, epoch "
               "rejection/retry, engine teardown deferred recovery\n";
}
