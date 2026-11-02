#pragma once
#include "registry.hpp"
#include "weapp/device_apis.hpp"

namespace weapp::flutter {
namespace device_adapter {
inline desktop::Value decode(const Json &json) {
  if (json.is_null()) return {};
  if (json.is_boolean()) return desktop::Value(json.get<bool>());
  if (json.is_number()) {
    // Epochs, sequence numbers and deadlines cross this typed SDK as strings.
    const double value=json.get<double>();
    if(!std::isfinite(value) || (json.is_number_integer() && std::abs(value)>9007199254740991.0))
      throw std::invalid_argument("native device integer must use an exact decimal string");
    return desktop::Value(value);
  }
  if (json.is_string()) return desktop::Value(json.get<std::string>());
  if (json.is_array()) { desktop::Value::Array values;for(const auto &value:json)values.push_back(decode(value));return desktop::Value(std::move(values)); }
  if (json.is_object()) { desktop::Value::Object values;for(auto it=json.begin();it!=json.end();++it)values.emplace(it.key(),decode(it.value()));return desktop::Value(std::move(values)); }
  throw std::invalid_argument("native device payload must be JSON data");
}
inline Json encode(const desktop::Value &value) {
  return std::visit([](const auto &item)->Json {
    using T=std::decay_t<decltype(item)>;
    if constexpr(std::is_same_v<T,std::monostate>) return nullptr;
    else if constexpr(std::is_same_v<T,desktop::Value::Array>) {Json result=Json::array();for(const auto &value:item)result.push_back(encode(value));return result;}
    else if constexpr(std::is_same_v<T,desktop::Value::Object>) {Json result=Json::object();for(const auto &value:item)result[value.first]=encode(value.second);return result;}
    else return item;
  },value.data);
}
inline Status status(const desktop::Status &value) {return {value.code,value.message};}
class Driver final : public NativeDeviceApis {
  std::unique_ptr<desktop::DeviceApis> driver_;
public:
  explicit Driver(std::unique_ptr<desktop::DeviceApis> driver):driver_(std::move(driver)){}
  Json configuration() const override {return encode(driver_->configuration());}
  bool dispatch(const Json &json) override {
    auto type=json.value("type","");
    desktop::Event event;
    event.type=type=="hostCall"?desktop::EventType::HostCall:type=="hostCallCancelled"?desktop::EventType::HostCallCancelled:desktop::EventType::Unknown;
    Json fields=json;fields.erase("type");event.fields=std::get<desktop::Value::Object>(decode(fields).data);
    return driver_->dispatch(event);
  }
  Status pump() override {return status(driver_->pump());}
  Status retire() override {return status(driver_->retire());}
  Status set_foreground(bool visible) override {return status(driver_->set_foreground(visible));}
  Status update_components(const Json &nodes) override {
    if(!nodes.is_array())return Status::error("ERR_ABI","hostComponents must return accepted component nodes");
    return status(driver_->update_components(std::get<desktop::Value::Array>(decode(nodes).data)));
  }
};
} // namespace device_adapter
// Parent is a host-owned NSView/HWND/GTK widget. Obtain its current value when
// creating each owner; the reusable DeviceApis implementation never owns it.
inline DeviceFactory native_device_api_factory(std::function<void *()> parent) {
  return [parent=std::move(parent)](const Json &trusted,const Json &options,const std::string &root,DeviceCommand command,Status &result)->std::unique_ptr<NativeDeviceApis> {
    try {
      desktop::DeviceApiOptions native;
      native.private_root=root;
      native.application=std::get<desktop::Value::Object>(device_adapter::decode(trusted.at("application")).data);
      native.account=std::get<desktop::Value::Object>(device_adapter::decode(trusted.at("account")).data);
      native.native_parent=parent ? parent() : nullptr;
      native.linux_desktop_id=options.value("linuxDesktopId","");
      if(options.contains("allowedNetworkOrigins")) native.allowed_network_origins=options.at("allowedNetworkOrigins").get<std::vector<std::string>>();
      desktop::Status status;
      auto driver=desktop::DeviceApis::create(native,[command=std::move(command)](const std::string &operation,const desktop::Value::Object &payload,desktop::Value *output) {
        Json json;auto result=command(operation,device_adapter::encode(payload),output?&json:nullptr);
        if(result && output)*output=device_adapter::decode(json);
        return desktop::Status{result.code,result.message};
      },status);
      result=device_adapter::status(status);
      if(!driver){if(result)result=Status::error("ERR_NATIVE_DEVICES","native device factory returned no driver");return {};}
      return std::make_unique<device_adapter::Driver>(std::move(driver));
    }catch(const std::exception &error){result=Status::error("ERR_NATIVE_DEVICES",error.what());return {};}
  };
}
} // namespace weapp::flutter
