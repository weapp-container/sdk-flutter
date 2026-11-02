#include "registry.hpp"
#include <cstring>
#include <limits>
#include <utility>

namespace weapp::flutter {
namespace {
bool schema_one(const Json &value) { return value.is_number() && value == 1; }
bool decimal_identity(const Json &value) {
  if (!value.is_string()) return false;
  const auto &text = value.get_ref<const std::string &>();
  constexpr const char *maximum = "18446744073709551615";
  if (text.empty() || text.size() > 20 || text.front() == '0') return false;
  for (const auto digit : text) if (digit < '0' || digit > '9') return false;
  return text.size() < 20 || text <= maximum;
}
bool root_identity(const Json &value) {
  if (!value.is_string()) return false;
  const auto &text = value.get_ref<const std::string &>();
  if (text.size() != 64) return false;
  for (const auto digit : text)
    if (!((digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f'))) return false;
  return true;
}
bool exact_keys(const Json &value, std::initializer_list<const char *> keys) {
  if (!value.is_object() || value.size() != keys.size()) return false;
  for (const auto *key : keys) if (!value.contains(key)) return false;
  return true;
}
bool accepted_identity(const Json &value) {
  return exact_keys(value, {"root", "acceptedPackRevision", "sessionId"}) &&
    root_identity(value.at("root")) && decimal_identity(value.at("acceptedPackRevision")) &&
    value.at("sessionId").is_string() && !value.at("sessionId").get_ref<const std::string &>().empty();
}
bool explicit_null(const Json &value, const char *key) {
  return value.contains(key) && value.at(key).is_null();
}
bool same_optional(const Json &left, const Json &right, const char *key) {
  const auto a = left.find(key), b = right.find(key);
  const bool absent_a = a == left.end() || a->is_null();
  const bool absent_b = b == right.end() || b->is_null();
  return absent_a || absent_b ? absent_a && absent_b : *a == *b;
}
bool valid_metrics(const Json &metrics) {
  if (!metrics.is_object() || metrics.size() < 8 || metrics.size() > 9) return false;
  for (const auto *key : {"windowWidth", "windowHeight", "screenWidth", "screenHeight",
                         "pixelRatio", "statusBarHeight", "screenTop"}) {
    if (!metrics.contains(key) || !metrics.at(key).is_number() ||
        !std::isfinite(metrics.at(key).get<double>())) return false;
  }
  for (const auto *key : {"windowWidth", "windowHeight", "screenWidth", "screenHeight"}) {
    const auto number = metrics.at(key).get<double>();
    if (number <= 0 || number > 16384 || std::floor(number) != number) return false;
  }
  if (metrics.at("pixelRatio").get<double>() <= 0 || metrics.at("statusBarHeight").get<double>() < 0 ||
      !metrics.contains("deviceOrientation") ||
      (metrics.at("deviceOrientation") != "portrait" && metrics.at("deviceOrientation") != "landscape")) return false;
  if (metrics.size() == 9 && !metrics.contains("safeArea")) return false;
  if (metrics.contains("safeArea") && !metrics.at("safeArea").is_null()) {
    const auto &area = metrics.at("safeArea");
    if (!exact_keys(area, {"left", "top", "right", "bottom", "width", "height"})) return false;
    for (const auto &field : area.items())
      if (!field.value().is_number() || !std::isfinite(field.value().get<double>())) return false;
    if (area.at("width").get<double>() < 0 || area.at("height").get<double>() < 0) return false;
  }
  return true;
}
bool valid_restart_proof(const Json &proof) {
  return exact_keys(proof, {"schemaVersion", "ownerId", "attemptId", "targetRoot", "expectedAccepted"}) &&
    schema_one(proof.at("schemaVersion")) && decimal_identity(proof.at("ownerId")) &&
    decimal_identity(proof.at("attemptId")) && root_identity(proof.at("targetRoot")) &&
    (proof.at("expectedAccepted").is_null() || accepted_identity(proof.at("expectedAccepted")));
}
bool restart_geometry_matches(const Json &chrome, const Metrics &metrics) {
  if (!chrome.is_object() || !chrome.contains("contentRect") || !chrome.contains("menuButtonRect")) return false;
  const auto &content = chrome.at("contentRect"), &menu = chrome.at("menuButtonRect");
  for (const auto *rectangle : {&content, &menu}) {
    if (!rectangle->is_object()) return false;
    for (const auto *key : {"left", "top", "width", "height"})
      if (!rectangle->contains(key) || !rectangle->at(key).is_number() ||
          !std::isfinite(rectangle->at(key).get<double>())) return false;
    for (const auto *key : {"width", "height"})
      if (rectangle->at(key).get<double>() <= 0 || rectangle->at(key).get<double>() > 16384) return false;
  }
  for (const auto *key : {"right", "bottom"})
    if (!menu.contains(key) || !menu.at(key).is_number() || !std::isfinite(menu.at(key).get<double>())) return false;
  if (std::abs(menu.at("right").get<double>() - menu.at("left").get<double>() - menu.at("width").get<double>()) > 1e-6 ||
      std::abs(menu.at("bottom").get<double>() - menu.at("top").get<double>() - menu.at("height").get<double>()) > 1e-6) return false;
  // Registry metrics contain the current native-derived screenTop, but no
  // independently measured screen X origin. Never claim X-origin proof here.
  return std::abs(content.at("width").get<double>() - metrics.value.at("windowWidth").get<double>()) <= 0.5 &&
    std::abs(content.at("height").get<double>() - metrics.value.at("windowHeight").get<double>()) <= 0.5 &&
    std::abs(content.at("top").get<double>() - metrics.value.at("screenTop").get<double>()) <= 0.5;
}
bool healthy(const Json &health) {
  return health.is_object() && health.contains("schemaVersion") && schema_one(health.at("schemaVersion")) &&
    health.contains("requiresRestart") && health.at("requiresRestart") == false &&
    explicit_null(health, "appServiceFault") && explicit_null(health, "viewFault") && explicit_null(health, "navigationFault");
}
bool view_fault_only(const Json &state, const Json &expected) {
  if (!accepted_identity(expected) || !state.contains("inputEnabled") || state.at("inputEnabled") != false ||
      !state.contains("presentationEnabled") || state.at("presentationEnabled") != false ||
      !state.contains("executionHealth")) return false;
  const auto &health = state.at("executionHealth");
  if (!health.is_object() || !health.contains("schemaVersion") || !schema_one(health.at("schemaVersion")) ||
      !health.contains("requiresRestart") || health.at("requiresRestart") != true ||
      !explicit_null(health, "appServiceFault") || !explicit_null(health, "navigationFault") ||
      !health.contains("viewFault") || !health.at("viewFault").is_object()) return false;
  const auto &fault = health.at("viewFault");
  if (!fault.contains("domain") || fault.at("domain") != "view" || !fault.contains("requiresRestart") || fault.at("requiresRestart") != true ||
      !fault.contains("code") || !fault.at("code").is_string() ||
      !fault.contains("message") || !fault.at("message").is_string() || fault.at("message").get_ref<const std::string &>().empty()) return false;
  const auto &code = fault.at("code").get_ref<const std::string &>();
  if (code.size() <= 4 || code.compare(0, 4, "ERR_") != 0) return false;
  for (std::size_t i = 4; i < code.size(); ++i)
    if (!((code[i] >= 'A' && code[i] <= 'Z') || (code[i] >= '0' && code[i] <= '9') || code[i] == '_')) return false;
  return true;
}
Status prepared_restart_layout(weapp_container_sdk_session *native, const Metrics &metrics,
                               const Json &payload) {
  const auto &proof = payload.at("restartAttempt");
  if (!valid_restart_proof(proof))
    return Status::error("ERR_PROTOCOL_VERSION", "Invalid prepared restart measurement proof");
  const auto &old = payload.at("observation");
  if (!old.is_object() || !old.contains("schemaVersion") || !schema_one(old.at("schemaVersion")) ||
      !old.contains("ownerId") || !decimal_identity(old.at("ownerId")) ||
      !old.contains("surfaceGeneration") || !decimal_identity(old.at("surfaceGeneration")) ||
      !old.contains("observationId") || !decimal_identity(old.at("observationId")) ||
      !payload.contains("layoutRevision") || !decimal_identity(payload.at("layoutRevision")) ||
      !old.contains("windowMetrics") || !valid_metrics(old.at("windowMetrics")))
    return Status::error("ERR_PROTOCOL_VERSION", "Invalid prepared restart observation");
  // Pure metadata queries on the already existing owner. In particular, do
  // not ensure, observe, drain, clear a fault or present while authorizing a
  // prospective restart rectangle. The copied caller proof is only a key.
  Json receipt, state;
  auto status = command(native, "queryDevPackAttempt", {
    {"ownerId", proof.at("ownerId")}, {"attemptId", proof.at("attemptId")}}, &receipt);
  if (status) status = command(native, "state", Json::object(), &state);
  if (!status) return status;
  if (!receipt.is_object() || !receipt.contains("schemaVersion") || !schema_one(receipt.at("schemaVersion")) ||
      !receipt.contains("status") || receipt.at("status") != "prepared" ||
      !receipt.contains("reloadKind") || receipt.at("reloadKind") != "restart" ||
      !receipt.contains("operation") || (receipt.at("operation") != "load" && receipt.at("operation") != "applyDevPack"))
    return Status::error("ERR_CANCELLED", "Prepared restart attempt is no longer current");
  for (const auto *key : {"ownerId", "attemptId", "targetRoot", "expectedAccepted"})
    if (!receipt.contains(key) || receipt.at(key) != proof.at(key))
      return Status::error("ERR_CANCELLED", "Prepared restart attempt identity changed");
  const auto &expected = proof.at("expectedAccepted");
  if (!state.is_object() || !state.contains("schemaVersion") || !schema_one(state.at("schemaVersion")) ||
      !state.contains("ownerId") || state.at("ownerId") != proof.at("ownerId") ||
      !state.contains("acceptedPackIdentity") || state.at("acceptedPackIdentity") != expected ||
      !receipt.contains("acceptedPackIdentity") || receipt.at("acceptedPackIdentity") != expected)
    return Status::error("ERR_CANCELLED", "Prepared restart accepted owner changed");
  const auto not_ready = Status::error("ERR_NOT_READY", "Prepared restart requires its exact current pending layout");
  if (!explicit_null(state, "pendingNavigation") || !state.contains("hostSurface") ||
      !state.at("hostSurface").is_object() || !state.contains("pendingHostLayout") || !state.at("pendingHostLayout").is_object()) return not_ready;
  const auto &surface = state.at("hostSurface"), &pending = state.at("pendingHostLayout");
  for (const auto *key : {"ownerId", "surfaceGeneration"})
    if (!surface.contains(key) || surface.at(key) != old.at(key)) return not_ready;
  if (old.at("ownerId") != proof.at("ownerId") || !pending.contains("schemaVersion") || !schema_one(pending.at("schemaVersion"))) return not_ready;
  for (const auto *key : {"ownerId", "surfaceGeneration", "observationId", "windowMetrics"})
    if (!pending.contains(key) || pending.at(key) != old.at(key)) return not_ready;
  for (const auto *key : {"sessionId", "pageId"})
    if (!same_optional(pending, old, key)) return not_ready;
  if (old.at("windowMetrics") != metrics.value || !payload.contains("chrome") ||
      !restart_geometry_matches(payload.at("chrome"), metrics)) return not_ready;
  if (state.contains("status") && state.at("status") == "empty") {
    for (const auto *key : {"executionHealth", "sessionId", "page", "acceptedPackIdentity", "acceptedLayout"})
      if (!explicit_null(state, key)) return not_ready;
    for (const auto *key : {"sessionId", "pageId"})
      if ((old.contains(key) && !old.at(key).is_null()) || (pending.contains(key) && !pending.at(key).is_null())) return not_ready;
  } else {
    if (!state.contains("status") || state.at("status") != "ready" || !accepted_identity(expected) ||
        !state.contains("sessionId") || state.at("sessionId") != expected.at("sessionId") ||
        !old.contains("sessionId") || old.at("sessionId") != state.at("sessionId") ||
        !state.contains("page") || !state.at("page").is_object() || !state.at("page").contains("id") ||
        !old.contains("pageId") || old.at("pageId").is_null() || old.at("pageId") != state.at("page").at("id") ||
        !state.contains("executionHealth") || (!healthy(state.at("executionHealth")) && !view_fault_only(state, expected))) return not_ready;
  }
  return {};
}
Status prepared_restart_capabilities(Json &value) {
  if (!value.is_object()) return Status::error("ERR_PROTOCOL_VERSION", "Invalid native capabilities");
  auto &chrome = value["chrome"];
  if (chrome.is_null()) chrome = Json::object();
  if (!chrome.is_object()) return Status::error("ERR_PROTOCOL_VERSION", "Invalid chrome capabilities");
  auto &atomic = chrome["atomicLayout"];
  if (atomic.is_null()) atomic = Json::object();
  if (!atomic.is_object()) return Status::error("ERR_PROTOCOL_VERSION", "Invalid atomic layout capabilities");
  atomic["preparedRestartMeasurement"] = "1.0";
  return {};
}
} // namespace
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
std::shared_ptr<const Frame>
Frame::acquire(weapp_container_sdk_session *s, Status &status,
               PresentationStamp stamp,
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
    status = Status::error(
        "ERR_CANCELLED",
        "Acquired pixels do not match the captured frame revision");
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
    for (auto key : {"previewX", "previewY"}) {
      if (a.contains(key) &&
          (!a[key].is_number() || !std::isfinite(a[key].get<double>()) ||
           a[key].get<double>() < 0 || a[key].get<double>() > 32767))
        return Status::error(
            "ERR_INVALID_ARGUMENT",
            "native preview origin must be finite and nonnegative");
      m.value.erase(key);
    }
    m.preview_x = a.value("previewX", 0.0);
    m.preview_y = a.value("previewY", 0.0);
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
  if (devices) devices->retire();
  devices.reset();
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
Status Registry::observe_layout(Entry &e, const Metrics &metrics) {
  if (e.host_surface.is_null()) {
    auto status = command(e.native, "hostSurface", {{"action", "attach"}}, &e.host_surface);
    if (!status) return status;
    e.host_layout_observed = false;
  }
  Json observation;
  auto status = command(e.native, "observeHostLayout", {
    {"schemaVersion", 1}, {"ownerId", e.host_surface.at("ownerId")},
    {"surfaceGeneration", e.host_surface.at("surfaceGeneration")},
    {"windowMetrics", metrics.value}}, &observation);
  if (status) e.host_layout_observed = true;
  return status;
}
Status Registry::retire_devices(Entry &e) {
  if(!e.devices)return {};
  auto status=e.devices->retire();
  if(status){e.devices.reset();e.device_session.clear();}
  return status;
}
Status Registry::prepare_devices(Entry &e,bool register_live) {
  if(e.devices || e.device_options.is_null())return {};
  if(!device_factory_)return Status::error("ERR_UNSUPPORTED_CAPABILITY","native device adapters are not installed in this platform plugin");
  if(!e.config.contains("hostServices"))return Status::error("ERR_HOST_SERVICES","native devices require trusted host services configuration");
  try {
    Status status;
    auto driver=device_factory_(e.config.at("hostServices"),e.device_options,root_,[&e](const std::string &operation,const Json &payload,Json *output){
      if(!e.native || e.closing || e.closed)return Status::error("ERR_CANCELLED","native device owner retired");
      return command(e.native,operation.c_str(),payload,output);
    },status);
    if(!status || !driver)return status ? Status::error("ERR_NATIVE_DEVICES","native device driver is unavailable") : status;
    auto native=driver->configuration();
    if(!native.is_object() || !native.value("apis",Json()).is_array() || !native.value("syncValues",Json()).is_object())
      return Status::error("ERR_NATIVE_DEVICES","native device configuration is malformed");
    auto &trusted=e.config["hostServices"];
    if(!trusted.contains("apis"))trusted["apis"]=Json::array();
    if(!trusted.contains("syncValues"))trusted["syncValues"]=Json::object();
    for(const auto &name:e.device_snapshot_names)trusted["syncValues"].erase(name);
    e.device_snapshot_names.clear();
    for(const auto &api:native["apis"]) {
      if(!api.is_string())return Status::error("ERR_NATIVE_DEVICES","native API name must be a string");
      if(std::find(trusted["apis"].begin(),trusted["apis"].end(),api)==trusted["apis"].end())trusted["apis"].push_back(api);
    }
    for(auto value=native["syncValues"].begin();value!=native["syncValues"].end();++value) {
      trusted["syncValues"][value.key()]=value.value();e.device_snapshot_names.insert(value.key());
    }
    if(register_live && !native["syncValues"].empty()) {
      status=command(e.native,"updateHostServiceSnapshots",{{"values",native["syncValues"]}});if(!status)return status;
    }
    e.devices=std::move(driver);return {};
  }catch(const std::exception &error){return Status::error("ERR_NATIVE_DEVICES",error.what());}
}
Status Registry::refresh_device_owner(Entry &e,const Json &state) {
  if(e.device_options.is_null())return {};
  const auto switch_state=state.value("accountSwitch",Json());
  const bool awaiting=state.value("status","")=="identitySwitching" && switch_state.is_object() && switch_state.value("phase","")=="awaitingPresentation";
  if(state.value("status","")!="ready" && !awaiting)return {};
  const auto incarnation=state.value("sessionId",Json());
  if(!incarnation.is_string())return {}; // older-runtime preflight fails before host service installation
  if(e.device_session==incarnation.get<std::string>() && e.devices)return {};
  auto status=retire_devices(e);if(!status)return status;
  const auto trusted=state.value("hostServicesState",Json());
  if(!trusted.is_object())return Status::error("ERR_PROTOCOL_VERSION","runtime omitted accepted host services identity");
  e.config["hostServices"]["application"]=trusted.at("application");
  e.config["hostServices"]["account"]=trusted.at("account");
  status=prepare_devices(e,true);
  if(status)e.device_session=incarnation.get<std::string>();
  return status;
}
Status Registry::ensure(Entry &e) {
  if (e.native) {
    return e.config.contains("hostLayout") && !e.host_layout_observed ? observe_layout(e, e.metrics) : Status{};
  }
  if (!e.metrics.width)
    return Status::error("ERR_NOT_LAID_OUT",
                         "initial measured viewport is required");
  Json display = e.metrics.value;
  display.erase("windowWidth");
  display.erase("windowHeight");
  Json config = e.config;
  if(!e.device_options.is_null())config["managedFilesRoot"]=root_;
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
  if(e.config.contains("hostServices")) {
    Json capabilities;
    result=command(e.native,"capabilities",Json::object(),&capabilities);
    if(!result) return result;
    if(capabilities.value("hostServices",Json::object()).value("protocolVersion","")!="1.0")
      return Status::error("ERR_PROTOCOL_VERSION","Runtime does not support host services protocol 1.0");
  }
  if(!e.device_options.is_null()) {
    result=prepare_devices(e);
    if(result)result=command(e.native,"configureHostServices",e.config.at("hostServices"));
    if(!result)return result;
  }
  for (auto &method : e.methods)
    if (auto s = command(e.native, "registerHostMethod", {{"name", method}});
        !s)
      return s;
  if (e.config.contains("hostLayout")) {
    auto status = observe_layout(e, e.metrics);
    if (!status) return status;
  }
  if (!e.config.contains("hostLayout") && !e.host_chrome.is_null()) {
    if (auto s = command(e.native, "hostChrome", e.host_chrome); !s)
      return s;
  }
  if (e.occluded) {
    if (auto s = command(e.native, "setPreviewOccluded", {{"occluded", true}});
        !s)
      return s;
  }
  return {};
}
Status Registry::foreground(Entry &e) {
  bool visible = e.foreground && bool(e.texture) && !e.retiring;
  if(e.devices){auto status=e.devices->set_foreground(visible);if(!status)return status;}
  if (e.texture) {
    auto shown = e.texture->set_visible(visible && !e.occluded);
    if (!shown)
      return shown;
  }
  if (!e.native || e.closing || e.closed)
    return {};
  Json state;
  auto s = command(e.native, "state", Json::object(), &state);
  if (!s || state.value("status", "") != "ready")
    return s;
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
    s = retire_devices(e);
    if(s)s = command(e.native, "load", a);
    Json state;
    auto observed = command(e.native, "state", Json::object(), &state);
    if (observed && state.value("status", "") == "ready") {
      if(state.value("hostServicesState",Json()).is_object()) {
        const auto &trusted=state["hostServicesState"];
        e.config["hostServices"]["application"]=trusted.at("application");
        e.config["hostServices"]["account"]=trusted.at("account");
      }
      auto devices=prepare_devices(e,true);if(s&&!devices)s=devices;
      if(state.value("sessionId",Json()).is_string())e.device_session=state.at("sessionId").get<std::string>();
      if (s && state.contains("hostChrome") &&
          state["hostChrome"].is_object()) {
        e.host_chrome = state["hostChrome"];
        e.host_chrome.erase("sessionId");
        e.host_chrome.erase("pageId");
      }
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
  if (e->native && !e->host_surface.is_null() && !e->closing) {
    auto identity = e->host_surface; identity["action"] = "detach";
    auto ended = command(e->native, "hostSurface", identity);
    if (!ended) { reply(ended, {}); return; }
    e->host_surface = nullptr;
    e->host_layout_observed = false;
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
  for (auto &pending : e->pending_prepares)
    pending(Status::error("ERR_CANCELLED",
                          "session closed before measured-view preparation"),
            {});
  e->pending_prepares.clear();
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
  auto device_status=retire_devices(*e);
  if(!device_status){auto replies=std::exchange(e->closes,{});for(auto &r:replies)r(device_status,{});return;}
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
Status Registry::prepare_account_cleanup(const std::shared_ptr<Entry> &e) {
  if (e->account_cleanup.empty()) return Status::error("ERR_ACCOUNT_CLEANUP","No account cleanup is pending");
  if (!e->account_native_cleanup) {
    if(auto status=retire_devices(*e);!status)return status;
    if (e->texture) {
      e->texture->invalidate_presentation();
      auto status=e->texture->suspend(e->native);
      if(!status) return status;
    }
    e->host_surface=nullptr; e->host_layout_observed=false; e->host_chrome=nullptr;
    e->account_native_cleanup=true;
  }
  if(emit_) emit_({{"id",e->id},{"event",{{"type","accountCleanupRequired"},{"operationId",e->account_cleanup}}}});
  return {};
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
    if (type == "accountSwitch") {
      if (event.contains("account") && event["account"].is_object())
        e->config["hostServices"]["account"] = event["account"];
      if(event.contains("syncValues") && event["syncValues"].is_object())
        e->config["hostServices"]["syncValues"]=event["syncValues"];
      auto phase = event.value("receipt", Json::object()).value("phase", "");
      if (phase == "revoking") {
        e->account_cleanup=event.at("receipt").at("operationId").get<std::string>();
        e->account_native_cleanup=false;
        report(e->id,prepare_account_cleanup(e));
      } else if (phase == "awaitingPresentation") {
        Json owner_state;auto status=command(e->native,"state",Json::object(),&owner_state);
        if(status)status=refresh_device_owner(*e,owner_state);
        report(e->id,status);
        if(status&&e->texture)report(e->id, e->texture->resume(e->native));
      }
    }
    if(e->devices && (type=="hostCall" || type=="hostCallCancelled")) {
      try{if(e->devices->dispatch(event))continue;}
      catch(const std::exception &error){report(e->id,Status::error("ERR_NATIVE_DEVICES",error.what()));}
    }
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
    if (e->texture && !e->retiring && e->foreground && !e->occluded) {
      auto consumed = e->texture->take_presented();
      if (consumed) {
        Json accepted;
        auto status = command(e->native, "state", Json::object(), &accepted);
        if (status && accepted.value("presentationRequired", false)) {
          Json receipt = {{"generation", consumed->generation}, {"revision", consumed->revision}};
          if (consumed->layout.is_object())
            for (const auto *key : {"ownerId", "surfaceGeneration", "observationId", "layoutRevision"})
              receipt[key] = consumed->layout.at(key);
          status = command(e->native, "presented", receipt, &accepted);
          // A newer accepted frame or detached surface intentionally cancels
          // this receipt. Never substitute the newly observed identity.
          if (!status && status.code != "ERR_CANCELLED")
            report(e->id, status);
        } else if (!status) {
          report(e->id, status);
        }
      }
    }
    if(!e->device_options.is_null()) {
      Json owner_state;auto status=command(e->native,"state",Json::object(),&owner_state);
      if(status)status=refresh_device_owner(*e,owner_state);
      report(e->id,status);
    }
    if(e->devices) {
      Json components;auto status=command(e->native,"hostComponents",Json::object(),&components);
      if(status)status=e->devices->update_components(components);
      if(status)status=e->devices->pump();
      report(e->id,status);
    }
    report(e->id, command(e->native, "pump"));
    Json state;
    if (command(e->native, "state", Json::object(), &state) &&
        state.value("presentationEnabled", false) && e->texture && !e->retiring &&
        e->foreground && !e->occluded &&
        state.value("chromeGeometryReady", true))
      report(e->id,
             e->texture->present(
                 e->native, e->metrics,
                 PresentationStamp{state.value("generation", uint64_t(0)),
                                   state.value("frameRevision", uint64_t(0)), state.value("acceptedLayout", Json())}));
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
      if (platform_ != "macos")
        e->config["gpuRequired"] = false;
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
      if (args.contains("gpuRequired")) {
        if (!args["gpuRequired"].is_boolean()) {
          reply(Status::error("ERR_INVALID_ARGUMENT",
                              "gpuRequired must be a boolean"),
                {});
          return;
        }
        if (args["gpuRequired"].get<bool>() && platform_ != "macos" &&
            !gpu_factory_) {
          // These Flutter plugins still expose CPU texture presenters. Native
          // desktop GL presenters must not be mislabeled as Flutter textures.
          reply(Status::error("ERR_UNSUPPORTED_CAPABILITY",
                              "GPU native preview is not attached to this "
                              "Flutter platform"),
                {});
          return;
        }
        e->config["gpuRequired"] = args["gpuRequired"];
      }
      if (args.contains("devDiagnostics")) {
        if (!args["devDiagnostics"].is_boolean()) {
          reply(Status::error("ERR_INVALID_ARGUMENT",
                              "devDiagnostics must be a boolean"),
                {});
          return;
        }
        e->config["devDiagnostics"] = args["devDiagnostics"];
      }
      if (args.contains("hostLayout")) e->config["hostLayout"] = args.at("hostLayout");
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
    if (method == "prepareHostLayout" || method == "hostLayout") {
      if (payload.contains("restartAttempt")) {
        const auto status = method == "prepareHostLayout"
          ? prepared_restart_layout(e->native, e->metrics, payload)
          : Status::error("ERR_PROTOCOL_VERSION", "restartAttempt is valid only for prepareHostLayout");
        if (!status) { reply(status, {}); return; }
      }
      const auto &observation = payload.at("observation");
      auto chrome = payload.at("chrome");
      chrome.erase("observationId");
      chrome.erase("sessionId"); chrome.erase("pageId");
      for (const auto *key : {"sessionId", "pageId"})
        if (observation.contains(key)) chrome[key] = observation.at(key);
      Json layout = {{"schemaVersion", 1}, {"ownerId", observation.at("ownerId")},
        {"surfaceGeneration", observation.at("surfaceGeneration")},
        {"observationId", observation.at("observationId")},
        {"layoutRevision", payload.at("layoutRevision")},
        {"windowMetrics", observation.at("windowMetrics")}, {"chrome", chrome}};
      if (method == "prepareHostLayout") reply({}, layout);
      else reply(command(e->native, "hostLayout", layout), nullptr);
      return;
    }
    if (method == "command") {
      auto status = ensure(*e);
      Json result;
      const auto operation = payload.at("operation").get<std::string>();
      const auto body = payload.value("payload", Json::object());
      bool suspended = false;
      if (status && operation == "applyDevPackAttempt") {
        Json attempt;
        status = command(e->native, "queryDevPackAttempt", {
          {"ownerId", body.at("ownerId")}, {"attemptId", body.at("attemptId")}}, &attempt);
        if (status && attempt.value("status", "") == "prepared" &&
            attempt.value("reloadKind", "") == "restart" && e->texture) {
          e->texture->invalidate_presentation();
          status = e->texture->suspend(e->native);
          suspended = bool(status);
        }
      }
      if (status) status = command(e->native, operation.c_str(), body, &result);
      if (operation == "applyDevPackAttempt" && !e->device_options.is_null()) {
        Json accepted;auto observed=command(e->native,"state",Json::object(),&accepted);
        if(observed)observed=refresh_device_owner(*e,accepted);
        if(status && !observed)status=observed;
      }
      if (operation == "applyDevPackAttempt") {
        auto lifecycle = foreground(*e);
        if (status && !lifecycle) status = lifecycle;
      }
      if (e->texture && operation == "applyDevPackAttempt") {
        e->texture->invalidate_presentation();
        if (suspended) {
          auto resumed = e->texture->resume(e->native);
          if (status && !resumed) status = resumed;
        }
      }
      reply(status, result);
      return;
    }
    if (method == "prepareHostChrome") {
      reply({}, payload);
      return;
    }
    if (method == "inspectPackChrome" ||
        (method == "hostChrome" && !e->native)) {
      weapp_container_sdk_session *temporary = nullptr;
      const std::string config = R"({"engine":"quickjs"})";
      Buffer created;
      auto status = created.read(weapp_container_sdk_session_new(
          reinterpret_cast<const uint8_t *>(config.data()), config.size(),
          &temporary, &created.value));
      Json result;
      if (status)
        status = command(temporary, method.c_str(), payload, &result);
      if (temporary) {
        Buffer retired;
        auto cleanup = retired.read(
            weapp_container_sdk_session_destroy(&temporary, &retired.value));
        if (!cleanup)
          status = cleanup;
      }
      if (status && method == "hostChrome")
        e->host_chrome = payload;
      reply(status, result);
      return;
    }
    if (method == "hostChrome") {
      auto status = command(e->native, "hostChrome", payload);
      if (status)
        e->host_chrome = payload;
      reply(status, nullptr);
      return;
    }
    if (method == "setPreviewOccluded") {
      const auto occluded = payload.at("occluded").get<bool>();
      auto status = e->native
                        ? command(e->native, "setPreviewOccluded", payload)
                        : Status{};
      if (status) {
        e->occluded = occluded;
        if (e->texture) {
          e->texture->invalidate_presentation();
          status = e->texture->set_visible(e->foreground && !occluded);
        }
      }
      reply(status, nullptr);
      return;
    }
    if (method == "nativeChrome") {
      auto weak = std::weak_ptr<Life>(life_);
      const auto id = e->id;
      auto action = [weak, id](Json event) {
        if (auto life = weak.lock();
            life && life->owner && life->owner->emit_) {
          event["type"] = "chromeAction";
          life->owner->emit_({{"id", id}, {"event", event}});
        }
      };
      auto status = e->texture
                        ? e->texture->set_chrome(payload, std::move(action))
                        : Status{};
      if (status)
        e->native_chrome = payload;
      reply(status, nullptr);
      return;
    }
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
      if (e->native && e->config.contains("hostLayout")) {
        s = observe_layout(*e, metrics);
      } else if (e->native) {
        Json state;
        s = command(e->native, "state", Json::object(), &state);
        if (s && state.value("status", "") == "empty") {
          s=retire_devices(*e);
          if(!s){reply(s,{});return;}
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
        const auto &factory =
            e->config.value("gpuRequired", false) && gpu_factory_ ? gpu_factory_
                                                                  : factory_;
        e->texture = factory(s, [weak, id](Status error) {
          if (auto life = weak.lock(); life && life->owner)
            life->owner->report(id, error);
        });
        if (!s || !e->texture) {
          reply(s ? Status::error("ERR_TEXTURE", "texture registration failed")
                  : s,
                {});
          return;
        }
        s = e->texture->layout(e->metrics);
        if (s && !e->native_chrome.is_null()) {
          auto weak_chrome = std::weak_ptr<Life>(life_);
          const auto chrome_id = e->id;
          s = e->texture->set_chrome(
              e->native_chrome, [weak_chrome, chrome_id](Json event) {
                if (auto life = weak_chrome.lock();
                    life && life->owner && life->owner->emit_) {
                  event["type"] = "chromeAction";
                  life->owner->emit_({{"id", chrome_id}, {"event", event}});
                }
              });
        }
        if (s && e->native) {
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
        reply({}, {{"textureId", e->texture->texture_id()},
                   {"nativePreview", e->texture->is_native_preview()}});
        auto prepares = std::exchange(e->pending_prepares, {});
        if (!prepares.empty()) {
          auto prepared = ensure(*e);
          Json capabilities;
          if (prepared)
            prepared = command(e->native, "capabilities", Json::object(),
                               &capabilities);
          if (prepared) prepared = prepared_restart_capabilities(capabilities);
          for (auto &pending : prepares)
            pending(prepared, capabilities);
        }
        if (e->pending_load) {
          auto pending = std::exchange(e->pending_load, {});
          auto pending_args = std::move(e->load);
          load(*e, pending_args, std::move(pending));
        }
      } else {
        if (e->texture)
          s = e->texture->layout(e->metrics);
        reply(s, nullptr);
      }
      return;
    }
    if (method == "observeHostLayout") {
      auto status = ensure(*e);
      if (status) status = observe_layout(*e, e->metrics);
      reply(status, nullptr); return;
    }
    if (method == "prepareView") {
      if (!e->metrics.width) {
        if (e->pending_prepares.size() >= 8)
          reply(
              Status::error("ERR_BUSY", "too many measured-view preparations"),
              {});
        else
          e->pending_prepares.push_back(std::move(reply));
        return;
      }
      auto status = ensure(*e);
      Json capabilities;
      if (status)
        status =
            command(e->native, "capabilities", Json::object(), &capabilities);
      if (status) status = prepared_restart_capabilities(capabilities);
      reply(status, capabilities);
      return;
    }
    if (method == "load") {
      load(*e, payload, std::move(reply));
      return;
    }
    if (method == "classifyDevPack") {
      auto status = ensure(*e);
      Json result;
      if (status)
        status = command(e->native, "classifyDevPack", payload, &result);
      reply(status, result);
      return;
    }
    if (method == "applyDevPack") {
      auto status = ensure(*e);
      Json classification;
      if (status)
        status =
            command(e->native, "classifyDevPack", payload, &classification);
      if (!status) {
        reply(status, {});
        return;
      }
      const auto kind = classification.value("reloadKind", "");
      if (kind != "restart" && kind != "inPlace") {
        reply(Status::error("ERR_PROTOCOL_VERSION",
                            "unknown native dev reload kind"),
              {});
        return;
      }
      if (kind == "restart") {
        // Reuse the normal detach/load/resume transaction; calling a runtime
        // restart underneath a live texture would violate GPU ownership.
        load(*e, payload,
             [e, reply = std::move(reply)](Status loaded, Json) mutable {
               Json state;
               if (loaded)
                 loaded = command(e->native, "state", Json::object(), &state);
               reply(loaded,
                     loaded ? Json{{"reloadKind", "restart"}, {"state", state}}
                            : Json());
             });
      } else {
        Json result;
        status = command(e->native, "applyDevPack", payload, &result);
        if (status && e->texture)
          e->texture->invalidate_presentation();
        reply(status, result);
      }
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
    if (method == "completeAccountCleanup") {
      const auto operation=args.at("operationId").get<std::string>();
      if(operation!=e->account_cleanup || !e->account_native_cleanup) { reply(Status::error("ERR_ACCOUNT_CLEANUP","Stale or incomplete native cleanup"),{}); return; }
      if(args.contains("error")) {
        report(e->id,Status::error("ERR_ACCOUNT_CLEANUP",args.at("error").value("message","Account cleanup failed")));
        reply({},nullptr); return;
      }
      auto status=command(e->native,"acknowledgeAccountCleanup",{{"operationId",operation}});
      if(status) {
        e->account_cleanup.clear();
        if(e->config.contains("hostLayout")) status=observe_layout(*e,e->metrics);
      }
      reply(status,nullptr); return;
    }
    if (method == "retryAccountCleanup") { reply(prepare_account_cleanup(e),nullptr); return; }
    if (method == "installNativeDeviceApis") {
      if(e->devices){reply(Status::error("ERR_BUSY","native devices are already installed for this owner"),{});return;}
      if(!e->config.contains("hostServices")){reply(Status::error("ERR_HOST_SERVICES","configure trusted host services before native devices"),{});return;}
      if(!device_factory_){reply(Status::error("ERR_UNSUPPORTED_CAPABILITY","native device adapter is unavailable"),{});return;}
      if(payload.contains("allowedNetworkOrigins")) {
        const auto &origins=payload.at("allowedNetworkOrigins");
        if(!origins.is_array() || origins.size()>128){reply(Status::error("ERR_INVALID_ARGUMENT","allowedNetworkOrigins must be a bounded list"),{});return;}
        for(const auto &origin:origins)if(!origin.is_string() || origin.get<std::string>().size()>2048){reply(Status::error("ERR_INVALID_ARGUMENT","network origin must be a bounded string"),{});return;}
      }
      e->device_options=payload;
      auto status=e->native?prepare_devices(*e):Status{};
      if(status && e->native)status=command(e->native,"configureHostServices",e->config.at("hostServices"));
      reply(status,nullptr);return;
    }
    if (method == "configureHostServices") {
      Status status;
      if(e->native) {
        Json capabilities;
        status=command(e->native,"capabilities",Json::object(),&capabilities);
        if(status && capabilities.value("hostServices",Json::object()).value("protocolVersion","")!="1.0")
          status=Status::error("ERR_PROTOCOL_VERSION","Runtime does not support host services protocol 1.0");
        if(status) status=command(e->native,"configureHostServices",payload);
      }
      if (status) e->config["hostServices"] = payload;
      reply(status, nullptr);
      return;
    }
    if (method == "registerApiHandler") {
      if (!e->config.contains("hostServices")) { reply(Status::error("ERR_INVALID_ARGUMENT","configure trusted host services first"),{}); return; }
      auto status = e->native ? command(e->native, "registerApiHandler", payload) : Status{};
      if (status) {
        auto &apis=e->config["hostServices"]["apis"];
        if(apis.is_null()) apis=Json::array();
        const auto name=args.at("name").get<std::string>();
        if(std::find(apis.begin(),apis.end(),Json(name))==apis.end()) apis.push_back(name);
      }
      reply(status,nullptr);
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
        "navigate",     "back",         "switchTab",        "sendMessage",
        "state",        "capabilities", "hostComponents", "completeHostCall", "input",
        "flushStorage", "devState",     "clearDevStorage",
        "hostApiEvent", "hostComponentFrame", "hostComponentEvent", "authorizePhoneButton", "prepareAccountHostServiceSnapshots", "updateHostServiceSnapshots", "switchAccount", "queryAccountSwitch",
        "updateAccountSwitchLaunch", "retryAccountSwitch", "cancelAccountSwitch",
        "createHostBinary", "readHostBinary", "retainHostBinary", "releaseHostBinary",
        "authorizeInstalledPack", "migrateLegacyStorage", "deleteAccountData"};
    if (!allowed.count(method)) {
      reply(Status::error("ERR_UNSUPPORTED",
                          "unknown desktop plugin method: " + method),
            {});
      return;
    }
    Json result;
    auto s = command(e->native, method.c_str(), payload, &result);
    if(s && (method=="prepareAccountHostServiceSnapshots" || method=="updateHostServiceSnapshots")) {
      auto &snapshots=e->config["hostServices"]["syncValues"];
      if(snapshots.is_null()) snapshots=Json::object();
      snapshots.update(payload.at("values"));
    }
    if (s && method == "capabilities") s = prepared_restart_capabilities(result);
    if (s && method == "clearDevStorage") {
      s = command(e->native, "flushStorage", Json::object(), &result);
      if (s && result.value("pending", false)) {
        e->flushes[result.at("ticket").get<uint64_t>()].push_back(
            std::move(reply));
        return;
      }
    }
    if (s && method == "flushStorage" && result.value("pending", false)) {
      e->flushes[result.at("ticket").get<uint64_t>()].push_back(
          std::move(reply));
      return;
    }
    reply(s,result);
  } catch (const std::exception &error) {
    reply(Status::error("ERR_INVALID_ARGUMENT", error.what()), {});
  }
}
bool Registry::cleanup(const std::shared_ptr<Entry> &e, const Log &log) {
  if (e->retiring)
    return false;
  if(auto status=retire_devices(*e);!status){log(status);return false;}
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
