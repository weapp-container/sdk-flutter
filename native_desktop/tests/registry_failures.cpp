#include "registry.hpp"
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
using namespace weapp::flutter;
struct weapp_container_sdk_session {
  bool ready = false, closed = false, input_enabled = false;
  uint64_t generation = 0, revision = 0;
  std::thread::id owner = std::this_thread::get_id();
};
static int destroy_failures = 0, live_sessions = 0;
static int ack_attempts = 0, successful_acks = 0;
static int guest_loads = 0;
static std::vector<std::pair<std::string, Json>> operations;
static Json native_config;
static bool presentation_required = false, ack_advances_frame = false;
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
    ++s->generation;
    ++s->revision;
    s->input_enabled = !presentation_required;
  }
  if (op == "navigate") {
    ++s->revision;
    s->input_enabled = !presentation_required;
  }
  if (op == "presented") {
    ++ack_attempts;
    auto stamp = Json::parse(payload, payload + payload_length);
    if (!presentation_required || stamp["generation"] != s->generation ||
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
  if (op == "state" || op == "presented")
    return response(b, {{"status", s->closed  ? "closed"
                                   : s->ready ? "ready"
                                              : "empty"},
                        {"foreground", true},
                        {"generation", s->generation},
                        {"frameRevision", s->revision},
                        {"presentationRequired", presentation_required},
                        {"inputEnabled", s->input_enabled}});
  if (op == "takeEvents")
    return response(b, Json::array());
  if (op == "capabilities")
    return response(b,
                    {{"pack", {{"devReload", {{"protocolVersion", "1.0"}}}}}});
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
  int suspended = 0, resumed = 0;
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
  auto make = [&] {
    return std::make_unique<Registry>(
        "macos", "/unused",
        [probe](Status &, std::function<void(Status)>) {
          return std::make_shared<TestTexture>(probe);
        },
        [](Json) {},
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
              prepared = true;
            });
  assert(!prepared && live_sessions == 0 && guest_loads == 0);
  call(*r, "attach", metrics(prepared_id));
  assert(prepared && live_sessions == 1 && guest_loads == 0);
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
