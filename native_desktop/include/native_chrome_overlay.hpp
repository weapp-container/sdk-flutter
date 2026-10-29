#pragma once
#include "registry.hpp"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#if defined(_WIN32)
#include <bcrypt.h>
#include <gdiplus.h>
#include <objidl.h>
#include <windows.h>
#elif defined(__linux__)
#include <gtk/gtk.h>
#endif

namespace weapp::flutter {
// Chrome is an OS sibling of the GPU child, never a Flutter texture or a
// screenshot of it. Geometry is one revision-bound measured host observation.
class NativeChromeOverlay {
public:
  virtual ~NativeChromeOverlay() = default;
  virtual Status update(const Json &, std::function<void(Json)>) = 0;
  virtual void visible(bool) = 0;
};
namespace chrome_detail {
struct Rect {
  double x = 0, y = 0, width = 0, height = 0;
};
inline Rect rect(const Json &value) {
  Rect r{value.at("left").get<double>(), value.at("top").get<double>(),
         value.at("width").get<double>(), value.at("height").get<double>()};
  for (double n : {r.x, r.y, r.width, r.height})
    if (!std::isfinite(n) || n < 0 || n > 32767)
      throw std::invalid_argument(
          "native chrome rectangles must be finite and bounded");
  if (r.width <= 0 || r.height <= 0)
    throw std::invalid_argument("empty native chrome rectangle");
  return r;
}
inline unsigned color(const Json &chrome, const char *key, unsigned fallback) {
  auto text = chrome.value(key, std::string());
  if (text.size() != 7 || text[0] != '#' ||
      text.find_first_not_of("0123456789abcdefABCDEF", 1) != std::string::npos)
    return fallback;
  return static_cast<unsigned>(std::stoul(text.substr(1), nullptr, 16));
}
// A custom page's navigation background need not match its content. Give the
// floating host controls their own contrasting backplate, derived from the
// declared foreground rather than that unrelated navigation background.
inline bool light_capsule_foreground(const Json &chrome) {
  auto foreground = color(chrome, "frontColor", 0x000000);
  return (((foreground >> 16) & 255) * 299 + ((foreground >> 8) & 255) * 587 +
          (foreground & 255) * 114) >= 128000;
}
inline unsigned capsule_background(const Json &chrome) {
  return light_capsule_foreground(chrome) ? 0x242424 : 0xf3f3f3;
}
inline std::vector<unsigned char> icon_bytes(const Json &descriptor) {
  const auto path = descriptor.at("path").get<std::string>(),
             mime = descriptor.at("mime").get<std::string>();
  const auto size = descriptor.at("size").get<size_t>();
  if ((mime != "image/png" && mime != "image/jpeg") || !size ||
      size > 4 * 1024 * 1024)
    throw std::invalid_argument("native tab icon requires a bounded PNG/JPEG");
  std::ifstream file(std::filesystem::u8path(path), std::ios::binary);
  if (!file)
    throw std::invalid_argument("native tab icon is unavailable");
  std::vector<unsigned char> bytes(size);
  file.read(reinterpret_cast<char *>(bytes.data()),
            static_cast<std::streamsize>(size));
  if (static_cast<size_t>(file.gcount()) != size ||
      file.peek() != std::char_traits<char>::eof())
    throw std::invalid_argument("native tab icon size mismatch");
  return bytes;
}
} // namespace chrome_detail

#if defined(_WIN32)
class WindowsChromeOverlay final : public NativeChromeOverlay {
  struct Plane {
    WindowsChromeOverlay *owner;
    HWND window = nullptr;
    bool tabs;
    std::vector<HWND> buttons;
  };
  HWND parent_;
  Plane toolbar_{this, nullptr, false}, tabs_{this, nullptr, true};
  Json value_;
  std::function<void(Json)> action_;
  bool shown_ = true;
  double scale_ = 1;
  ULONG_PTR gdiplus_ = 0;
  struct Image {
    std::shared_ptr<IStream> stream;
    std::unique_ptr<Gdiplus::Bitmap> bitmap;
  };
  std::map<std::string, Image> icons_;
  static std::wstring wide(const std::string &s) {
    int length = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                     static_cast<int>(s.size()), nullptr, 0);
    std::wstring result(length, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                        result.data(), length);
    return result;
  }
  static COLORREF rgb(unsigned c) {
    return RGB((c >> 16) & 255, (c >> 8) & 255, c & 255);
  }
  void load_icons(const Json &bar) {
    std::map<std::string, Image> images;
    for (const auto &item : bar.at("list"))
      for (auto field : {"iconFile", "selectedIconFile"}) {
        if (!item.contains(field) || item[field].is_null())
          continue;
        const auto &descriptor = item.at(field);
        const auto hash = descriptor.at("sha256").get<std::string>();
        if (images.count(hash))
          continue;
        auto bytes = chrome_detail::icon_bytes(descriptor);
        BCRYPT_ALG_HANDLE algorithm = nullptr;
        if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) != 0)
          throw std::invalid_argument("native icon SHA-256 unavailable");
        unsigned char digest[32]{};
        const auto status = BCryptHash(algorithm, nullptr, 0, bytes.data(),
                                       static_cast<ULONG>(bytes.size()), digest,
                                       sizeof(digest));
        BCryptCloseAlgorithmProvider(algorithm, 0);
        std::ostringstream hex;
        for (auto byte : digest)
          hex << std::hex << std::setw(2) << std::setfill('0')
              << static_cast<unsigned>(byte);
        if (status != 0 || hex.str() != hash)
          throw std::invalid_argument("native tab icon SHA-256 mismatch");
        if (!gdiplus_) {
          Gdiplus::GdiplusStartupInput input;
          if (Gdiplus::GdiplusStartup(&gdiplus_, &input, nullptr) !=
              Gdiplus::Ok)
            throw std::invalid_argument("native tab icon decoder unavailable");
        }
        HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
        if (!memory)
          throw std::bad_alloc();
        void *data = GlobalLock(memory);
        if (!data) {
          GlobalFree(memory);
          throw std::bad_alloc();
        }
        std::memcpy(data, bytes.data(), bytes.size());
        GlobalUnlock(memory);
        IStream *stream = nullptr;
        if (FAILED(CreateStreamOnHGlobal(memory, TRUE, &stream))) {
          GlobalFree(memory);
          throw std::invalid_argument("native icon stream allocation failed");
        }
        Image image;
        image.stream = {stream, [](IStream *p) { p->Release(); }};
        image.bitmap = std::make_unique<Gdiplus::Bitmap>(stream, FALSE);
        if (image.bitmap->GetLastStatus() != Gdiplus::Ok ||
            !image.bitmap->GetWidth() || !image.bitmap->GetHeight() ||
            image.bitmap->GetWidth() > 1024 || image.bitmap->GetHeight() > 1024)
          throw std::invalid_argument(
              "native tab icon decoding failed or exceeds budget");
        images.emplace(hash, std::move(image));
      }
    icons_ = std::move(images);
  }
  static LRESULT CALLBACK proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto *plane =
        reinterpret_cast<Plane *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      plane = static_cast<Plane *>(
          reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(plane));
    }
    if (!plane)
      return DefWindowProcW(window, message, w, l);
    if (message == WM_ERASEBKGND)
      return 1;
    if (message == WM_PAINT) {
      plane->owner->paint(*plane);
      return 0;
    }
    if (message == WM_DRAWITEM) {
      plane->owner->draw_button(*reinterpret_cast<DRAWITEMSTRUCT *>(l),
                                plane->tabs);
      return TRUE;
    }
    if (message == WM_COMMAND && HIWORD(w) == BN_CLICKED) {
      plane->owner->button_action(*plane, LOWORD(w));
      return 0;
    }
    if (message == WM_LBUTTONUP) {
      plane->owner->activate(*plane, static_cast<short>(LOWORD(l)),
                             static_cast<short>(HIWORD(l)));
      return 0;
    }
    if (message == WM_KEYUP && (w == VK_RETURN || w == VK_SPACE)) {
      plane->owner->emit("more");
      return 0;
    }
    return DefWindowProcW(window, message, w, l);
  }
  void emit(const std::string &action, const std::string &route = {}) {
    if (!action_)
      return;
    Json event{{"action", action}, {"revision", value_.at("revision")}};
    if (!route.empty())
      event["route"] = route;
    action_(std::move(event));
  }
  bool custom() const {
    return value_.at("chrome").value("navigationStyle", "default") == "custom";
  }
  chrome_detail::Rect plane_rect(bool tabs) const {
    return chrome_detail::rect(value_.at(tabs       ? "tabBarRect"
                                         : custom() ? "menuButtonRect"
                                                    : "toolbarRect"));
  }
  void button_action(Plane &plane, unsigned id) {
    if (id == 100)
      emit("more");
    else if (id == 101)
      emit("close");
    else if (id == 102)
      emit("back");
    else if (plane.tabs && id >= 200) {
      const auto &list = value_.at("chrome").at("tabBar").at("list");
      const auto index = id - 200;
      if (index < list.size())
        emit("switchTab", list[index].value("pagePath", ""));
    }
  }
  void draw_button(const DRAWITEMSTRUCT &item, bool tabs) {
    const auto &chrome = value_.at("chrome");
    const auto &colors = tabs ? chrome.at("tabBar") : chrome;
    const bool capsule = !tabs && (item.CtlID == 100 || item.CtlID == 101);
    auto brush = CreateSolidBrush(rgb(
        capsule ? chrome_detail::capsule_background(chrome)
                : chrome_detail::color(colors, "backgroundColor", 0xffffff)));
    FillRect(item.hDC, &item.rcItem, brush);
    DeleteObject(brush);
    SetBkMode(item.hDC, TRANSPARENT);
    SetTextColor(item.hDC,
                 rgb(chrome_detail::color(
                     colors,
                     tabs ? (colors.value("selectedIndex", -1) ==
                                     static_cast<int>(item.CtlID - 200)
                                 ? "selectedColor"
                                 : "color")
                          : "frontColor",
                     0x000000)));
    std::wstring text = item.CtlID == 100   ? L"···"
                        : item.CtlID == 101 ? L"⊙"
                                            : L"‹";
    if (tabs) {
      const auto &list = colors.at("list");
      if (item.CtlID - 200 < list.size())
        text = wide(list[item.CtlID - 200].value("text", ""));
    }
    RECT bounds = item.rcItem;
    if (tabs) {
      const auto &tab = colors.at("list").at(item.CtlID - 200);
      const auto selected = colors.value("selectedIndex", -1) ==
                            static_cast<int>(item.CtlID - 200);
      auto field = selected && tab.contains("selectedIconFile")
                       ? "selectedIconFile"
                       : "iconFile";
      if (tab.contains(field) && !tab[field].is_null()) {
        auto found = icons_.find(tab.at(field).at("sha256").get<std::string>());
        if (found != icons_.end()) {
          Gdiplus::Graphics graphics(item.hDC);
          const auto size = static_cast<int>(22 * scale_);
          graphics.DrawImage(found->second.bitmap.get(),
                             (bounds.right - size) / 2,
                             static_cast<int>(3 * scale_), size, size);
          bounds.top += static_cast<LONG>(26 * scale_);
        }
      }
    }
    DrawTextW(item.hDC, text.c_str(), -1, &bounds,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    if (item.itemState & ODS_FOCUS) {
      InflateRect(&bounds, -2, -2);
      DrawFocusRect(item.hDC, &bounds);
    }
  }
  void buttons(Plane &plane) {
    for (auto button : plane.buttons)
      DestroyWindow(button);
    plane.buttons.clear();
    auto add = [&](unsigned id, const std::wstring &label, double x, double y,
                   double width, double height) {
      auto button = CreateWindowExW(
          0, L"BUTTON", label.c_str(),
          WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
          static_cast<int>(std::lround(x * scale_)),
          static_cast<int>(std::lround(y * scale_)),
          static_cast<int>(std::lround(width * scale_)),
          static_cast<int>(std::lround(height * scale_)), plane.window,
          reinterpret_cast<HMENU>(static_cast<UINT_PTR>(id)),
          GetModuleHandleW(nullptr), nullptr);
      if (button)
        plane.buttons.push_back(button);
    };
    const auto outer = plane_rect(plane.tabs);
    const auto &chrome = value_.at("chrome");
    if (plane.tabs) {
      const auto &list = chrome.at("tabBar").at("list");
      for (size_t i = 0; i < list.size(); ++i)
        add(static_cast<unsigned>(200 + i), wide(list[i].value("text", "")),
            outer.width * i / list.size(), 0, outer.width / list.size(),
            outer.height);
    } else {
      const auto pill = chrome_detail::rect(value_.at("menuButtonRect"));
      const auto left = pill.x - outer.x, top = pill.y - outer.y;
      add(100, L"More", left + 1, top + 1, pill.width / 2 - 2, pill.height - 2);
      add(101, L"Close mini-program", left + pill.width / 2 + 1, top + 1,
          pill.width / 2 - 2, pill.height - 2);
      if (!custom() && chrome.value("canGoBack", false))
        add(102, L"Back", 0, 0, 44, outer.height);
    }
  }
  void paint(Plane &plane) {
    PAINTSTRUCT ps{};
    HDC dc = BeginPaint(plane.window, &ps);
    RECT bounds{};
    GetClientRect(plane.window, &bounds);
    const auto &chrome = value_.at("chrome");
    const auto &colors = plane.tabs ? chrome.at("tabBar") : chrome;
    auto brush = CreateSolidBrush(
        rgb(!plane.tabs && custom()
                ? chrome_detail::capsule_background(chrome)
                : chrome_detail::color(colors, "backgroundColor", 0xffffff)));
    FillRect(dc, &bounds, brush);
    DeleteObject(brush);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc,
                 rgb(chrome_detail::color(
                     colors, plane.tabs ? "color" : "frontColor", 0x000000)));
    auto font = CreateFontW(-static_cast<int>(15 * scale_), 0, 0, 0, FW_NORMAL,
                            FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    auto old_font = SelectObject(dc, font);
    if (plane.tabs) {
      const auto &bar = chrome.at("tabBar");
      const auto &list = bar.at("list");
      for (size_t i = 0; i < list.size(); ++i) {
        RECT cell{static_cast<LONG>(bounds.right * i / list.size()), 0,
                  static_cast<LONG>(bounds.right * (i + 1) / list.size()),
                  bounds.bottom};
        SetTextColor(dc,
                     rgb(chrome_detail::color(bar,
                                              bar.value("selectedIndex", -1) ==
                                                      static_cast<int>(i)
                                                  ? "selectedColor"
                                                  : "color",
                                              0x333333)));
        const auto text = wide(list[i].value("text", ""));
        DrawTextW(dc, text.c_str(), -1, &cell,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      }
    } else {
      auto outer = plane_rect(false);
      auto capsule = chrome_detail::rect(value_.at("menuButtonRect"));
      RECT pill{
          static_cast<LONG>((capsule.x - outer.x) * scale_),
          static_cast<LONG>((capsule.y - outer.y) * scale_),
          static_cast<LONG>((capsule.x - outer.x + capsule.width) * scale_),
          static_cast<LONG>((capsule.y - outer.y + capsule.height) * scale_)};
      if (!custom()) {
        RECT title = bounds;
        title.left += static_cast<LONG>(48 * scale_);
        title.right = pill.left - static_cast<LONG>(8 * scale_);
        auto text = wide(chrome.value("title", ""));
        DrawTextW(dc, text.c_str(), -1, &title,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        if (chrome.value("canGoBack", false)) {
          RECT back{0, 0, static_cast<LONG>(44 * scale_), bounds.bottom};
          DrawTextW(dc, L"‹", -1, &back,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
      }
      auto pen = CreatePen(PS_SOLID, 1, rgb(0x999999));
      auto old_pen = SelectObject(dc, pen);
      auto capsule_brush =
          CreateSolidBrush(rgb(chrome_detail::capsule_background(chrome)));
      auto old_brush = SelectObject(dc, capsule_brush);
      RoundRect(dc, pill.left, pill.top, pill.right, pill.bottom,
                static_cast<int>(32 * scale_), static_cast<int>(32 * scale_));
      auto mid = (pill.left + pill.right) / 2;
      MoveToEx(dc, mid, pill.top + static_cast<int>(8 * scale_), nullptr);
      LineTo(dc, mid, pill.bottom - static_cast<int>(8 * scale_));
      RECT more = pill, close = pill;
      more.right = mid;
      close.left = mid;
      DrawTextW(dc, L"···", -1, &more, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      DrawTextW(dc, L"⊙", -1, &close, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      SelectObject(dc, old_brush);
      DeleteObject(capsule_brush);
      SelectObject(dc, old_pen);
      DeleteObject(pen);
    }
    SelectObject(dc, old_font);
    DeleteObject(font);
    EndPaint(plane.window, &ps);
  }
  void activate(Plane &plane, int x, int y) {
    auto outer = plane_rect(plane.tabs);
    const auto &chrome = value_.at("chrome");
    const double logical_x = x / scale_, logical_y = y / scale_;
    if (plane.tabs) {
      auto list = chrome.at("tabBar").at("list");
      auto index = static_cast<size_t>(logical_x * list.size() / outer.width);
      if (index < list.size())
        emit("switchTab", list[index].value("pagePath", ""));
    } else {
      auto pill = chrome_detail::rect(value_.at("menuButtonRect"));
      if (logical_x >= pill.x - outer.x &&
          logical_x <= pill.x - outer.x + pill.width &&
          logical_y >= pill.y - outer.y &&
          logical_y <= pill.y - outer.y + pill.height)
        emit(logical_x < pill.x - outer.x + pill.width / 2 ? "more" : "close");
      else if (!custom() && logical_x < 44 && chrome.value("canGoBack", false))
        emit("back");
    }
  }
  Status position(Plane &plane) {
    if (!plane.window) {
      WNDCLASSW c{};
      c.lpfnWndProc = proc;
      c.hInstance = GetModuleHandleW(nullptr);
      c.lpszClassName = L"WeappContainerNativeChrome";
      c.hCursor = LoadCursor(nullptr, IDC_ARROW);
      RegisterClassW(&c);
      plane.window = CreateWindowExW(WS_EX_CONTROLPARENT, c.lpszClassName,
                                     plane.tabs ? L"Mini-program tabs"
                                                : L"Mini-program navigation",
                                     WS_CHILD | WS_TABSTOP, 0, 0, 1, 1, parent_,
                                     nullptr, c.hInstance, &plane);
      if (!plane.window)
        return Status::error("ERR_RENDER",
                             "could not create native chrome HWND");
    }
    auto r = plane_rect(plane.tabs);
    auto extended = GetWindowLongPtrW(plane.window, GWL_EXSTYLE);
    const bool floating = !plane.tabs && custom();
    SetWindowLongPtrW(plane.window, GWL_EXSTYLE,
                      floating ? extended | WS_EX_LAYERED
                               : extended & ~WS_EX_LAYERED);
    if (floating &&
        !SetLayeredWindowAttributes(plane.window, 0, 240, LWA_ALPHA))
      return Status::error("ERR_RENDER",
                           "could not set native capsule opacity");
    SetWindowPos(
        plane.window, HWND_TOP, static_cast<int>(std::lround(r.x * scale_)),
        static_cast<int>(std::lround(r.y * scale_)),
        static_cast<int>(std::lround(r.width * scale_)),
        static_cast<int>(std::lround(r.height * scale_)), SWP_NOACTIVATE);
    if (!plane.tabs && custom())
      SetWindowRgn(plane.window,
                   CreateRoundRectRgn(0, 0,
                                      static_cast<int>(r.width * scale_) + 1,
                                      static_cast<int>(r.height * scale_) + 1,
                                      static_cast<int>(32 * scale_),
                                      static_cast<int>(32 * scale_)),
                   TRUE);
    else
      SetWindowRgn(plane.window, nullptr, TRUE);
    buttons(plane);
    ShowWindow(plane.window, shown_ ? SW_SHOWNA : SW_HIDE);
    InvalidateRect(plane.window, nullptr, FALSE);
    return {};
  }

public:
  explicit WindowsChromeOverlay(void *parent)
      : parent_(static_cast<HWND>(parent)) {}
  ~WindowsChromeOverlay() override {
    if (toolbar_.window)
      DestroyWindow(toolbar_.window);
    if (tabs_.window)
      DestroyWindow(tabs_.window);
    icons_.clear();
    if (gdiplus_)
      Gdiplus::GdiplusShutdown(gdiplus_);
  }
  Status update(const Json &value, std::function<void(Json)> action) override {
    try {
      if (value.at("schemaVersion") != 1 ||
          (!value.at("revision").is_number_unsigned() &&
           !value.at("revision").is_number_integer()))
        throw std::invalid_argument("invalid native chrome version");
      chrome_detail::rect(value.at("toolbarRect"));
      chrome_detail::rect(value.at("menuButtonRect"));
      value.at("chrome").at("navigationStyle").get<std::string>();
      if (!value_.is_null() && value.at("revision").get<uint64_t>() <
                                   value_.at("revision").get<uint64_t>())
        return Status::error("ERR_CANCELLED", "stale native chrome revision");
      load_icons(value.at("chrome").at("tabBar"));
      value_ = value;
      action_ = std::move(action);
      scale_ = GetDpiForWindow(parent_) / 96.0;
      auto status = position(toolbar_);
      if (!status)
        return status;
      if (value_.contains("tabBarRect") && !value_["tabBarRect"].is_null() &&
          value_.at("chrome").at("tabBar").value("visible", false))
        return position(tabs_);
      if (tabs_.window)
        ShowWindow(tabs_.window, SW_HIDE);
      return {};
    } catch (const std::exception &e) {
      return Status::error("ERR_INVALID_ARGUMENT", e.what());
    }
  }
  void visible(bool value) override {
    shown_ = value;
    if (!value_.is_null()) {
      position(toolbar_);
      if (tabs_.window)
        ShowWindow(
            tabs_.window,
            value && value_.at("chrome").at("tabBar").value("visible", false)
                ? SW_SHOWNA
                : SW_HIDE);
    }
  }
};
#elif defined(__linux__)
class GtkChromeOverlay final : public NativeChromeOverlay {
  GtkWidget *parent_, *fixed_ = nullptr;
  Json value_;
  std::function<void(Json)> action_;
  bool shown_ = true;
  using Pixbuf = std::shared_ptr<GdkPixbuf>;
  std::map<std::string, Pixbuf> icons_;
  void load_icons(const Json &bar) {
    std::map<std::string, Pixbuf> images;
    for (const auto &item : bar.at("list"))
      for (auto field : {"iconFile", "selectedIconFile"}) {
        if (!item.contains(field) || item[field].is_null())
          continue;
        const auto &descriptor = item.at(field);
        const auto hash = descriptor.at("sha256").get<std::string>();
        if (images.count(hash))
          continue;
        auto bytes = chrome_detail::icon_bytes(descriptor);
        g_autofree gchar *actual = g_compute_checksum_for_data(
            G_CHECKSUM_SHA256, bytes.data(), bytes.size());
        if (!actual || hash != actual)
          throw std::invalid_argument("native tab icon SHA-256 mismatch");
        auto *loader = gdk_pixbuf_loader_new();
        GError *error = nullptr;
        const bool ok = gdk_pixbuf_loader_write(loader, bytes.data(),
                                                bytes.size(), &error) &&
                        gdk_pixbuf_loader_close(loader, &error);
        auto *image = ok ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
        if (!image || gdk_pixbuf_get_width(image) > 1024 ||
            gdk_pixbuf_get_height(image) > 1024) {
          if (error)
            g_error_free(error);
          g_object_unref(loader);
          throw std::invalid_argument(
              "native tab icon decoding failed or exceeds budget");
        }
        auto *small =
            gdk_pixbuf_scale_simple(image, 22, 22, GDK_INTERP_BILINEAR);
        g_object_unref(loader);
        if (error)
          g_error_free(error);
        if (!small)
          throw std::bad_alloc();
        images.emplace(hash,
                       Pixbuf(small, [](GdkPixbuf *p) { g_object_unref(p); }));
      }
    icons_ = std::move(images);
  }
  struct Action {
    GtkChromeOverlay *owner;
    std::string name, route;
  };
  static void clicked(GtkButton *, gpointer data) {
    auto *a = static_cast<Action *>(data);
    if (!a->owner->action_)
      return;
    Json event{{"action", a->name},
               {"revision", a->owner->value_.at("revision")}};
    if (!a->route.empty())
      event["route"] = a->route;
    a->owner->action_(std::move(event));
  }
  GtkWidget *button(const char *text, const char *label,
                    const std::string &action, const std::string &route = {}) {
    auto *widget = gtk_button_new_with_label(text);
    gtk_widget_set_tooltip_text(widget, label);
    atk_object_set_name(gtk_widget_get_accessible(widget), label);
    auto *data = new Action{this, action, route};
    g_signal_connect_data(
        widget, "clicked", G_CALLBACK(clicked), data,
        [](gpointer p, GClosure *) { delete static_cast<Action *>(p); },
        GConnectFlags(0));
    return widget;
  }
  void put(GtkWidget *widget, chrome_detail::Rect r) {
    gtk_widget_set_size_request(widget, static_cast<int>(std::lround(r.width)),
                                static_cast<int>(std::lround(r.height)));
    gtk_fixed_put(GTK_FIXED(fixed_), widget, static_cast<int>(std::lround(r.x)),
                  static_cast<int>(std::lround(r.y)));
  }
  static void style(GtkWidget *widget, const std::string &css) {
    auto *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, css.c_str(), -1, nullptr);
    gtk_style_context_add_provider(gtk_widget_get_style_context(widget),
                                   GTK_STYLE_PROVIDER(provider),
                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
  }

public:
  explicit GtkChromeOverlay(void *parent) : parent_(GTK_WIDGET(parent)) {}
  ~GtkChromeOverlay() override {
    if (fixed_)
      gtk_widget_destroy(fixed_);
  }
  Status update(const Json &value, std::function<void(Json)> action) override {
    try {
      if (value.at("schemaVersion") != 1)
        throw std::invalid_argument("invalid native chrome version");
      auto toolbar = chrome_detail::rect(value.at("toolbarRect")),
           pill = chrome_detail::rect(value.at("menuButtonRect"));
      if (!value_.is_null() && value.at("revision").get<uint64_t>() <
                                   value_.at("revision").get<uint64_t>())
        return Status::error("ERR_CANCELLED", "stale native chrome revision");
      if (!GTK_IS_OVERLAY(parent_))
        return Status::error("ERR_RENDER",
                             "native chrome requires GTK overlay parent");
      load_icons(value.at("chrome").at("tabBar"));
      value_ = value;
      action_ = std::move(action);
      if (fixed_)
        gtk_widget_destroy(fixed_);
      fixed_ = gtk_fixed_new();
      gtk_widget_set_halign(fixed_, GTK_ALIGN_FILL);
      gtk_widget_set_valign(fixed_, GTK_ALIGN_FILL);
      gtk_overlay_add_overlay(GTK_OVERLAY(parent_), fixed_);
      const auto &chrome = value.at("chrome");
      const bool custom =
          chrome.value("navigationStyle", "default") == "custom";
      if (!custom) {
        auto *header = gtk_event_box_new();
        style(header, "* {background-color:" +
                          chrome.value("backgroundColor", "#ffffff") +
                          "; color:" + chrome.value("frontColor", "#000000") +
                          ";}");
        auto *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_container_add(GTK_CONTAINER(header), row);
        if (chrome.value("canGoBack", false)) {
          auto *back = button("‹", "Back", "back");
          gtk_widget_set_size_request(back, 44,
                                      static_cast<int>(toolbar.height));
          gtk_box_pack_start(GTK_BOX(row), back, FALSE, FALSE, 0);
        }
        auto *label = gtk_label_new(chrome.value("title", "").c_str());
        gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        gtk_box_pack_start(GTK_BOX(row), label, TRUE, TRUE, 0);
        auto *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_set_size_request(spacer, static_cast<int>(pill.width + 16),
                                    1);
        gtk_box_pack_end(GTK_BOX(row), spacer, FALSE, FALSE, 0);
        put(header, toolbar);
      }
      auto *capsule = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
      const auto backplate = chrome_detail::light_capsule_foreground(chrome)
                                 ? "rgba(24,24,24,0.84)"
                                 : "rgba(255,255,255,0.90)";
      style(capsule,
            std::string("* {border-radius:16px; background-image:none; ") +
                "background-color:" + backplate +
                "; color:" + chrome.value("frontColor", "#000000") + ";}");
      gtk_box_pack_start(GTK_BOX(capsule), button("···", "More", "more"), TRUE,
                         TRUE, 0);
      gtk_box_pack_start(GTK_BOX(capsule),
                         button("⊙", "Close mini-program", "close"), TRUE, TRUE,
                         0);
      put(capsule, pill);
      const auto &bar = chrome.at("tabBar");
      if (value.contains("tabBarRect") && !value["tabBarRect"].is_null() &&
          bar.value("visible", false)) {
        auto r = chrome_detail::rect(value.at("tabBarRect"));
        auto *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        style(row, "* {background-color:" +
                       bar.value("backgroundColor", "#ffffff") + ";}");
        int index = 0;
        for (const auto &item : bar.at("list")) {
          auto text = item.value("text", "");
          auto route = item.value("pagePath", "");
          auto *tab = button(text.c_str(), text.c_str(), "switchTab", route);
          const bool selected = index++ == bar.value("selectedIndex", -1);
          auto field = selected && item.contains("selectedIconFile")
                           ? "selectedIconFile"
                           : "iconFile";
          if (item.contains(field) && !item[field].is_null()) {
            auto found =
                icons_.find(item.at(field).at("sha256").get<std::string>());
            if (found != icons_.end()) {
              auto *old = gtk_bin_get_child(GTK_BIN(tab));
              if (old)
                gtk_container_remove(GTK_CONTAINER(tab), old);
              auto *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
              gtk_box_pack_start(GTK_BOX(column),
                                 gtk_image_new_from_pixbuf(found->second.get()),
                                 FALSE, FALSE, 0);
              gtk_box_pack_start(GTK_BOX(column), gtk_label_new(text.c_str()),
                                 FALSE, FALSE, 0);
              gtk_container_add(GTK_CONTAINER(tab), column);
            }
          }
          style(tab,
                "* {color:" +
                    bar.value(selected ? "selectedColor" : "color", "#333333") +
                    ";}");
          gtk_box_pack_start(GTK_BOX(row), tab, TRUE, TRUE, 0);
        }
        put(row, r);
      }
      gtk_widget_show_all(fixed_);
      visible(shown_);
      return {};
    } catch (const std::exception &e) {
      return Status::error("ERR_INVALID_ARGUMENT", e.what());
    }
  }
  void visible(bool value) override {
    shown_ = value;
    if (!fixed_)
      return;
    if (value) {
      gtk_overlay_reorder_overlay(GTK_OVERLAY(parent_), fixed_, -1);
      gtk_widget_show(fixed_);
    } else
      gtk_widget_hide(fixed_);
  }
};
#endif
inline std::shared_ptr<NativeChromeOverlay>
create_native_chrome_overlay(void *parent) {
#if defined(_WIN32)
  return std::make_shared<WindowsChromeOverlay>(parent);
#elif defined(__linux__)
  return std::make_shared<GtkChromeOverlay>(parent);
#else
  (void)parent;
  return {};
#endif
}
} // namespace weapp::flutter
