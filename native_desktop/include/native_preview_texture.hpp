#pragma once
#include "native_chrome_overlay.hpp"
#include "registry.hpp"
#include "weapp/native_preview.hpp"

namespace weapp::flutter {
// A native child view deliberately has no Flutter texture. It occupies the
// reserved measured rectangle, and receives native OS input there. It borrows
// the Registry's exact runtime; retirement never destroys or pumps that
// runtime.
class NativePreviewTexture final : public Texture {
public:
  explicit NativePreviewTexture(std::shared_ptr<void> parent,
                                std::function<void(Status)> errors)
      : parent_(std::move(parent)), errors_(std::move(errors)),
        chrome_(create_native_chrome_overlay(parent_.get())) {}
  int64_t texture_id() const override { return -1; }
  bool is_native_preview() const override { return true; }
  Status layout(const Metrics &metrics) override {
    metrics_ = metrics;
    return preview_ ? convert(preview_->set_bounds(bounds())) : Status{};
  }
  Status set_visible(bool visible) override {
    visible_ = visible;
    auto result = preview_ ? convert(preview_->set_visible(visible)) : Status{};
    if (chrome_)
      chrome_->visible(visible);
    return result;
  }
  Status set_chrome(const Json &value,
                    std::function<void(Json)> action) override {
    if (!chrome_)
      return Status::error("ERR_UNSUPPORTED_CAPABILITY",
                           "native chrome is unavailable");
    auto status = chrome_->update(value, std::move(action));
    if (status)
      chrome_->visible(visible_);
    return status;
  }
  Status resume(weapp_container_sdk_session *runtime) override {
    if (preview_)
      return {};
    const auto &m = metrics_.value;
    weapp::desktop::Metrics native{m.at("windowWidth").get<uint32_t>(),
                                   m.at("windowHeight").get<uint32_t>(),
                                   m.at("pixelRatio").get<double>(),
                                   m.at("screenWidth").get<uint32_t>(),
                                   m.at("screenHeight").get<uint32_t>(),
                                   m.at("screenTop").get<double>()};
    weapp::desktop::Status status;
    auto errors = errors_;
    preview_ = weapp::desktop::NativePreview::create(
        runtime, parent_.get(), native, bounds(),
        [errors](weapp::desktop::Status value) {
          if (errors)
            errors(convert(value));
        },
        status);
    if (!status)
      return convert(status);
    return set_visible(visible_);
  }
  Status suspend(weapp_container_sdk_session *) override {
    if (!preview_)
      return {};
    auto status = preview_->detach();
    if (status)
      preview_.reset();
    return convert(status);
  }
  Status present(weapp_container_sdk_session *, const Metrics &,
                 PresentationStamp) override {
    if (!preview_)
      return Status::error("ERR_SURFACE_DETACHED",
                           "native GPU preview is not attached");
    return convert(preview_->present());
  }
  void retire(std::function<void(Status)> done) override {
    auto status = suspend(nullptr);
    done(status);
  }

private:
  static Status convert(const weapp::desktop::Status &value) {
    return {value.code, value.message};
  }
  weapp::desktop::Rect bounds() const {
    return {metrics_.preview_x, metrics_.preview_y,
            metrics_.value.at("windowWidth").get<double>(),
            metrics_.value.at("windowHeight").get<double>()};
  }
  std::shared_ptr<void> parent_;
  std::function<void(Status)> errors_;
  Metrics metrics_;
  bool visible_ = true;
  std::unique_ptr<weapp::desktop::NativePreview> preview_;
  std::shared_ptr<NativeChromeOverlay> chrome_;
};
} // namespace weapp::flutter
