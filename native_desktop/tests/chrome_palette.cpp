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
}
