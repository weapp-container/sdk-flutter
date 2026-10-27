#include "registry.hpp"
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
static bool presentation_required = false, ack_advances_frame = false;
static int32_t response(weapp_container_sdk_buffer *out, Json value,
                        bool ok = true, const char *code = "ERR_INJECTED") {
  auto bytes = (ok ? Json{{"ok", true}, {"value", value}}
                   : Json{{"ok", false},
                          {"error",
                           {{"code", code},
                            {"message", "injected transient failure"}}}})
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
int32_t weapp_container_sdk_session_new(const uint8_t *, size_t,
                                        weapp_container_sdk_session **s,
                                        weapp_container_sdk_buffer *b) {
  *s = new weapp_container_sdk_session;
  ++live_sessions;
  return response(b, nullptr);
}
int32_t weapp_container_sdk_session_command(weapp_container_sdk_session *s,
                                            const uint8_t *operation,
                                            size_t length, const uint8_t *payload,
                                            size_t payload_length,
                                            weapp_container_sdk_buffer *b) {
  std::string op(reinterpret_cast<const char *>(operation), length);
  assert(s->owner == std::this_thread::get_id());
  if (op == "load") {
    s->ready = true; ++s->generation; ++s->revision;
    s->input_enabled = !presentation_required;
  }
  if (op == "navigate") { ++s->revision; s->input_enabled = !presentation_required; }
  if (op == "presented") {
    ++ack_attempts;
    auto stamp = Json::parse(payload, payload + payload_length);
    if (!presentation_required || stamp["generation"] != s->generation || stamp["revision"] != s->revision)
      return response(b, nullptr, false, "ERR_CANCELLED");
    ++successful_acks;
    s->input_enabled = true;
    if (ack_advances_frame) { ack_advances_frame = false; ++s->revision; s->input_enabled = false; }
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
  std::function<void(Status)> pending;
  bool async = false;
  struct Receipt {
    std::shared_ptr<PresentationFeedback> feedback;
    PresentationFeedback::Ticket ticket;
    void consume() const { feedback->consumed(ticket); }
  };
  std::vector<Receipt> receipts;
};
class TestTexture : public Texture {
public:
  explicit TestTexture(std::shared_ptr<Probe> p) : p_(std::move(p)) {
    ++p_->live;
  }
  ~TestTexture() override { --p_->live; }
  int64_t texture_id() const override { return 42; }
  Status present(weapp_container_sdk_session *, const Metrics &,
                 PresentationStamp stamp) override {
    if (!last_stamp_ || !(*last_stamp_ == stamp)) {
      p_->receipts.push_back({feedback_, feedback_->submitted(stamp)});
      last_stamp_ = stamp;
    }
    return {};
  }
  Status suspend(weapp_container_sdk_session *) override {
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
    std::thread raster([receipt] { receipt.consume(); }); raster.join();
  };
  auto first = probe->receipts.back();
  consume(first);
  assert(ack_attempts == 0); // Raster thread never enters the runtime.
  r->tick();
  assert(successful_acks == 1);
  assert(call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(first); r->tick();
  assert(ack_attempts == 1); // Duplicate reads are bounded and deduplicated.

  call(*r, "navigate", {{"id", id}, {"route", "second"}}); r->tick();
  auto stale = probe->receipts.back();
  call(*r, "navigate", {{"id", id}, {"route", "third"}}); r->tick();
  auto current = probe->receipts.back();
  consume(stale); r->tick();
  assert(ack_attempts == 2 && successful_acks == 1);
  assert(!call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(current); r->tick();
  assert(successful_acks == 2);

  call(*r, "navigate", {{"id", id}, {"route", "ready-hook"}}); r->tick();
  current = probe->receipts.back();
  ack_advances_frame = true; consume(current); r->tick();
  assert(successful_acks == 3);
  auto after_ready = probe->receipts.back();
  assert(after_ready.ticket.stamp.revision == current.ticket.stamp.revision + 1);
  assert(!call(*r, "state", {{"id", id}})["inputEnabled"].get<bool>());
  consume(after_ready); r->tick();
  assert(successful_acks == 4);

  call(*r, "navigate", {{"id", id}, {"route", "before-reload"}}); r->tick();
  stale = probe->receipts.back();
  call(*r, "load", {{"id", id}, {"packPath", "/new-generation"}});
  auto attempts = ack_attempts;
  consume(stale); r->tick();
  assert(ack_attempts == attempts);
  current = probe->receipts.back();
  assert(current.ticket.stamp.generation == stale.ticket.stamp.generation + 1);
  consume(current); r->tick();
  assert(successful_acks == 5);

  call(*r, "navigate", {{"id", id}, {"route", "before-detach"}}); r->tick();
  stale = probe->receipts.back();
  attempts = ack_attempts;
  call(*r, "detach", {{"id", id}});
  consume(stale); r->tick();
  assert(ack_attempts == attempts && successful_acks == 5);
  call(*r, "close", {{"id", id}});

  // Raster-only SDKs keep their established ready semantics and never receive
  // the native-GPU-only command merely because Flutter consumed CPU pixels.
  presentation_required = false;
  attempts = ack_attempts;
  id = create(); r->tick();
  consume(probe->receipts.back()); r->tick();
  assert(ack_attempts == attempts && successful_acks == 5);
  call(*r, "close", {{"id", id}});
  r.reset();
  assert(live_sessions == 0 && probe->live == 0);
  PresentationFeedback bounded;
  auto older = bounded.submitted({1, 1}), newer = bounded.submitted({1, 2});
  bounded.consumed(newer); bounded.consumed(older);
  assert(bounded.take()->revision == 2 && !bounded.take());
  auto invalidated = bounded.submitted({1, 3});
  bounded.invalidate(); bounded.consumed(invalidated);
  assert(!bounded.take());
  std::cout << "PASS texture-consumption ACK ownership, duplicate/late/epoch "
               "rejection, ready-hook frame mutation, CPU legacy isolation\n";
  std::cout << "PASS close error settlement/retry, unregister ownership, epoch "
               "rejection/retry, engine teardown deferred recovery\n";
}
