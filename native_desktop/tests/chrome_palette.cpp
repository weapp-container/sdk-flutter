#include "native_chrome_overlay.hpp"
#include <cassert>

int main() {
  using namespace weapp::flutter;
  // A white foreground remains readable when a custom page inherits the
  // default white navigation background but draws entirely different content.
  Json light{{"frontColor", "#ffffff"}, {"backgroundColor", "#ffffff"}};
  Json dark{{"frontColor", "#000000"}, {"backgroundColor", "#000000"}};
  assert(chrome_detail::capsule_background(light) == 0x242424);
  assert(chrome_detail::capsule_background(dark) == 0xf3f3f3);
  light["backgroundColor"] = "#07c160";
  assert(chrome_detail::capsule_background(light) == 0x242424);
  assert(!chrome_detail::light_capsule_foreground(Json::object()));

  // Localized host names are optional and independent from page-owned titles
  // or tab text. Existing consumers keep precisely the former English names.
  const auto defaults = chrome_detail::accessibility_labels(Json::object());
  assert(defaults.more == "More");
  assert(defaults.close == "Close mini-program");
  assert(defaults.back == "Back");
  assert(defaults.navigation == "Mini-program navigation");
  assert(defaults.tabs == "Mini-program tabs");
  Json descriptor{{"accessibilityLabels",
                   {{"more", "更多"},
                    {"close", "关闭小程序"},
                    {"back", "返回"},
                    {"navigation", "小程序导航"},
                    {"tabs", "小程序标签栏"}}}};
  auto chinese = chrome_detail::accessibility_labels(descriptor);
  assert(chinese.more == "更多" && chinese.close == "关闭小程序");
  assert(chinese.back == "返回" && chinese.navigation == "小程序导航");
  assert(chinese.tabs == "小程序标签栏");
  descriptor["accessibilityLabels"] = {{"more", "更多"}};
  auto partial = chrome_detail::accessibility_labels(descriptor);
  assert(partial.more == "更多" && partial.back == defaults.back);
  auto rejected = [](const Json &labels) {
    try {
      chrome_detail::accessibility_labels(
          Json{{"accessibilityLabels", labels}});
      return false;
    } catch (const std::invalid_argument &) {
      return true;
    }
  };
  assert(rejected(nullptr));
  assert(rejected(Json::array()));
  assert(rejected(Json{{"more", 1}}));
  assert(rejected(Json{{"close", ""}}));
  assert(rejected(Json{{"back", std::string(1025, 'x')}}));
  assert(rejected(Json{{"navigation", std::string("hidden\0suffix", 13)}}));
}
