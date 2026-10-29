#include "include/weapp_container_linux/weapp_container_linux_plugin.h"
#include "registry.hpp"
#include "native_preview_texture.hpp"
#include <filesystem>
#if defined(GDK_WINDOWING_X11)
#include <gdk/gdkx.h>
#endif
using namespace weapp::flutter;
namespace {
// Flutter Linux FlValue stores strings as NUL-terminated gchar*, including
// strings decoded by StandardMethodCodec. Keep the public JSON data lossless by
// carrying JSON UTF-8 in Uint8List envelopes on this platform.
Json fromValue(FlValue *value) {
  if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST)
    throw std::invalid_argument(
        "Linux channel arguments require JSON UTF-8 bytes");
  auto bytes = fl_value_get_uint8_list(value);
  return Json::parse(bytes, bytes + fl_value_get_length(value));
}
FlValue *toValue(const Json &value) {
  const auto bytes = value.dump();
  return fl_value_new_uint8_list(
      reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
}
struct PixelState {
  Mailbox mailbox;
  // Only the raster callback replaces this lease. Publication from the owner
  // thread cannot release pixels while Flutter uploads after copy_pixels
  // returns.
  std::shared_ptr<const Frame> reader;
};
} // namespace
typedef struct _WeappPixelTexture {
  FlPixelBufferTexture parent;
  PixelState *state;
} WeappPixelTexture;
typedef struct _WeappPixelTextureClass {
  FlPixelBufferTextureClass parent;
} WeappPixelTextureClass;
G_DEFINE_TYPE(WeappPixelTexture, weapp_pixel_texture,
              fl_pixel_buffer_texture_get_type())
static gboolean weapp_pixel_texture_copy(FlPixelBufferTexture *texture,
                                         const uint8_t **buffer,
                                         uint32_t *width, uint32_t *height,
                                         GError **) {
  auto self = reinterpret_cast<WeappPixelTexture *>(texture);
  self->state->reader = self->state->mailbox.read();
  if (!self->state->reader) {
    // Registration precedes the first rendered frame, including a background
    // reattach. This is a valid empty surface. Flutter Linux dereferences
    // GError on FALSE, so a missing frame must not be reported as an error.
    static const uint8_t transparent[4] = {};
    *buffer = transparent;
    *width = *height = 1;
    return TRUE;
  }
  auto &info = self->state->reader->info;
  *buffer = info.data;
  *width = info.width;
  *height = info.height;
  // Flutter has requested these exact pixels on its raster thread.
  self->state->reader->feedback->consumed(self->state->reader->presentation);
  return TRUE;
}
static void weapp_pixel_texture_finalize(GObject *object) {
  delete reinterpret_cast<WeappPixelTexture *>(object)->state;
  G_OBJECT_CLASS(weapp_pixel_texture_parent_class)->finalize(object);
}
static void weapp_pixel_texture_class_init(WeappPixelTextureClass *klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = weapp_pixel_texture_copy;
  G_OBJECT_CLASS(klass)->finalize = weapp_pixel_texture_finalize;
}
static void weapp_pixel_texture_init(WeappPixelTexture *self) {
  self->state = new PixelState();
}
namespace {
struct PixelSlot {
  WeappPixelTexture *texture = reinterpret_cast<WeappPixelTexture *>(
      g_object_new(weapp_pixel_texture_get_type(), nullptr));
  bool leased = false;
  ~PixelSlot() { g_object_unref(texture); }
};
// The Linux registrar returns a borrowed texture to the raster thread and
// exposes no unregister completion callback. Preserve the GObject and its
// reader until engine shutdown, reusing slots at the active-texture high-water
// mark. Registry/session handles still retire immediately. Flutter shuts down
// raster tasks before destroying the messenger handlers that own this pool.
class PixelPool {
public:
  std::shared_ptr<PixelSlot> acquire() {
    for (auto &slot : slots_)
      if (!slot->leased) {
        slot->leased = true;
        slot->texture->state->mailbox.publish(nullptr);
        return slot;
      }
    auto slot = std::make_shared<PixelSlot>();
    slot->leased = true;
    slots_.push_back(slot);
    return slot;
  }

private:
  std::vector<std::shared_ptr<PixelSlot>> slots_;
};
class LinuxTexture final : public Texture {
public:
  LinuxTexture(FlTextureRegistrar *registrar, std::shared_ptr<PixelPool> pool)
      : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(registrar))),
        pool_(std::move(pool)), slot_(pool_->acquire()),
        texture_(slot_->texture) {}
  ~LinuxTexture() override {
    slot_->leased = false;
    g_object_unref(registrar_);
  }
  bool initialize() {
    registered_ =
        fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_));
    return registered_;
  }
  int64_t texture_id() const override {
    return fl_texture_get_id(FL_TEXTURE(texture_));
  }
  Status present(weapp_container_sdk_session *native, const Metrics &,
                 PresentationStamp stamp) override {
    if (last_stamp_ && stamp == *last_stamp_)
      return {};
    Status status;
    auto frame = Frame::acquire(native, status, stamp, feedback_);
    if (!status)
      return status.code == "ERR_NO_FRAME" ? Status{} : status;
    if (frame->info.stride != frame->info.width * 4)
      return Status::error("ERR_FRAME",
                           "Flutter textures require tightly packed RGBA");
    texture_->state->mailbox.publish(frame);
    last_stamp_ = stamp;
    return fl_texture_registrar_mark_texture_frame_available(
               registrar_, FL_TEXTURE(texture_))
               ? Status{}
               : Status::error("ERR_TEXTURE",
                               "Flutter rejected frame notification");
  }
  void retire(std::function<void(Status)> done) override {
    // Clearing the producer is safe; only the raster callback replaces the
    // reader lease after its preceding upload completed. The pool retains both
    // the object and that final reader while an unregister can still be queued.
    texture_->state->mailbox.publish(nullptr);
    if (registered_) {
      if (!fl_texture_registrar_unregister_texture(registrar_,
                                                   FL_TEXTURE(texture_)) &&
          FL_TEXTURE_REGISTRAR_GET_IFACE(registrar_)
                  ->lookup_texture(registrar_, texture_id()) != nullptr) {
        done(Status::error(
            "ERR_TEXTURE",
            "Flutter texture unregister failed; texture remains owned"));
        return;
      }
      registered_ = false;
    }
    done({});
  }

private:
  FlTextureRegistrar *registrar_;
  std::shared_ptr<PixelPool> pool_;
  std::shared_ptr<PixelSlot> slot_;
  WeappPixelTexture *texture_;
  bool registered_ = false;
  std::optional<PresentationStamp> last_stamp_;
};
struct Plugin {
  std::unique_ptr<Registry> registry;
  std::shared_ptr<GtkWidget> view;
  // Borrowed from messenger-owned channels. The channel destroy callbacks
  // clear these before dropping their final shared ownership of Plugin.
  FlMethodChannel *methods = nullptr;
  FlEventChannel *events = nullptr;
  bool listening = false;
  guint timer = 0;
  ~Plugin() {
    if (timer)
      g_source_remove(timer);
    listening = false;
    registry.reset();
  }
};
using PluginRef = std::shared_ptr<Plugin>;

void reply(FlMethodCall *call, Status status, Json value) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (status) {
    g_autoptr(FlValue) result = toValue(value);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        status.code.c_str(), status.message.c_str(), nullptr));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error))
    g_warning("WeApp Container reply failed: %s", error->message);
}
void methodCall(FlMethodChannel *, FlMethodCall *call, gpointer data) {
  auto plugin = *static_cast<PluginRef *>(data);
  auto retained =
      std::shared_ptr<FlMethodCall>(FL_METHOD_CALL(g_object_ref(call)),
                                    [](FlMethodCall *p) { g_object_unref(p); });
  try {
    Json arguments = fromValue(fl_method_call_get_args(call));
    const std::string method = fl_method_call_get_name(call);
    const bool layout_method=method=="hostLayout"||method=="prepareHostLayout";
    const bool chrome_method=layout_method||method=="hostChrome"||method=="prepareHostChrome";
    const bool client_chrome = chrome_method && arguments.value("coordinateSpace", "screen") == "flutterClient";
    if (client_chrome || method == "attach" || method == "resize") {
      auto *view = plugin->view.get();
      auto *display = view ? gtk_widget_get_display(view) : nullptr;
      bool x11 = false;
#if defined(GDK_WINDOWING_X11)
      x11 = display && GDK_IS_X11_DISPLAY(display);
#endif
      if (client_chrome && !x11) {
        reply(call, Status::error("ERR_UNSUPPORTED_CAPABILITY", "Wayland does not expose the screen origin required by host chrome"), {}); return;
      }
      auto *top = view ? gtk_widget_get_toplevel(view) : nullptr;
      auto *window = top ? gtk_widget_get_window(top) : nullptr;
      gint x=0,y=0,offset_x=0,offset_y=0;
      if(x11 && window && gtk_widget_translate_coordinates(view,top,0,0,&offset_x,&offset_y) && gdk_window_get_origin(window,&x,&y)) {
        auto *monitor=gdk_display_get_monitor_at_window(display,window);GdkRectangle extent{};
        if(monitor)gdk_monitor_get_geometry(monitor,&extent);
        const double dx=x+offset_x-extent.x,dy=y+offset_y-extent.y;
        if(client_chrome){arguments.erase("coordinateSpace");translate_chrome(layout_method ? arguments.at("chrome") : arguments,dx,dy);}
        else arguments["screenTop"]=dy+arguments.value("previewY",0.0);
      } else if(client_chrome) {
        reply(call, Status::error("ERR_NOT_READY", "Chrome needs a realized native X11 host window"), {}); return;
      }
    }
    if(chrome_method)arguments.erase("coordinateSpace");
    plugin->registry->invoke(
        method, arguments,
        [retained](Status s, Json value) { reply(retained.get(), s, value); });
  } catch (const std::exception &error) {
    reply(call, Status::error("ERR_INVALID_ARGUMENT", error.what()), {});
  }
}
FlMethodErrorResponse *listen(FlEventChannel *, FlValue *, gpointer data) {
  (*static_cast<PluginRef *>(data))->listening = true;
  return nullptr;
}
FlMethodErrorResponse *cancel(FlEventChannel *, FlValue *, gpointer data) {
  (*static_cast<PluginRef *>(data))->listening = false;
  return nullptr;
}
std::string storageRoot() {
  auto app = g_application_get_default();
  const char *id = app ? g_application_get_application_id(app) : nullptr;
  return (std::filesystem::path(g_get_user_data_dir()) /
          (id ? id : "weapp-container") / "weapp-container")
      .string();
}
} // namespace
void weapp_container_linux_plugin_register_with_registrar(
    FlPluginRegistrar *registrar) {
  auto owner = std::make_shared<Plugin>();
  auto plugin = owner.get();
  auto textures = std::shared_ptr<FlTextureRegistrar>(
      FL_TEXTURE_REGISTRAR(
          g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar))),
      [](FlTextureRegistrar *value) { g_object_unref(value); });
  auto pool = std::make_shared<PixelPool>();
  plugin->registry = std::make_unique<Registry>(
      "linux", storageRoot(),
      [textures, pool](Status &status, std::function<void(Status)>)
          -> std::shared_ptr<Texture> {
        auto texture = std::make_shared<LinuxTexture>(textures.get(), pool);
        if (!texture->initialize()) {
          status = Status::error("ERR_TEXTURE",
                                 "Flutter refused texture registration");
          return {};
        }
        return texture;
      },
      [plugin](Json event) {
        if (!plugin->listening)
          return;
        g_autoptr(FlValue) value = toValue(event);
        g_autoptr(GError) error = nullptr;
        if (!fl_event_channel_send(plugin->events, value, nullptr, &error))
          g_warning("WeApp Container event failed: %s", error->message);
      },
      [](std::function<bool()> retry) {
        auto callback = new std::function<bool()>(std::move(retry));
        g_timeout_add_full(
            G_PRIORITY_DEFAULT, 50,
            [](gpointer data) -> gboolean {
              return (*static_cast<std::function<bool()> *>(data))()
                         ? G_SOURCE_REMOVE
                         : G_SOURCE_CONTINUE;
            },
            callback,
            [](gpointer data) {
              delete static_cast<std::function<bool()> *>(data);
            });
      },
      [](Status status) {
        g_warning("WeApp Container deferred cleanup: %s: %s",
                  status.code.c_str(), status.message.c_str());
      });
  auto view = std::shared_ptr<GtkWidget>(
      GTK_WIDGET(g_object_ref(fl_plugin_registrar_get_view(registrar))),
      [](GtkWidget* value) { g_object_unref(value); });
  plugin->view = view;
  plugin->registry->set_gpu_preview_factory(
      [view](Status& status, std::function<void(Status)> errors) -> std::shared_ptr<Texture> {
        auto* parent = gtk_widget_get_parent(view.get());
        if (!parent || !GTK_IS_CONTAINER(parent)) {
          status = Status::error("ERR_RENDER", "native Flutter view parent is unavailable");
          return {};
        }
        GtkWidget* overlay = parent;
        if (!GTK_IS_OVERLAY(parent)) {
          overlay = gtk_overlay_new();
          // Keep the FlView alive across reparenting. Its native GPU sibling
          // occupies only the explicitly measured preview rectangle.
          g_object_ref(view.get());
          gtk_container_remove(GTK_CONTAINER(parent), view.get());
          gtk_container_add(GTK_CONTAINER(overlay), view.get());
          gtk_container_add(GTK_CONTAINER(parent), overlay);
          g_object_unref(view.get());
          gtk_widget_show(overlay);
          gtk_widget_show(view.get());
        }
        auto owner = std::shared_ptr<void>(g_object_ref(overlay),
            [](void* value) { g_object_unref(value); });
        return std::make_shared<NativePreviewTexture>(std::move(owner), std::move(errors));
      });
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto messenger = fl_plugin_registrar_get_messenger(registrar);
  plugin->methods = fl_method_channel_new(
      messenger, "dev.weapp.container/methods", FL_METHOD_CODEC(codec));
  plugin->events = fl_event_channel_new(messenger, "dev.weapp.container/events",
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->methods, methodCall, new PluginRef(owner), [](gpointer data) {
        auto reference = static_cast<PluginRef *>(data);
        (*reference)->methods = nullptr;
        delete reference;
      });
  fl_event_channel_set_stream_handlers(
      plugin->events, listen, cancel, new PluginRef(owner), [](gpointer data) {
        auto reference = static_cast<PluginRef *>(data);
        (*reference)->events = nullptr;
        (*reference)->listening = false;
        delete reference;
      });
  g_object_unref(plugin->methods);
  g_object_unref(plugin->events);
  plugin->timer = g_timeout_add_full(
      G_PRIORITY_DEFAULT, 16,
      [](gpointer data) -> gboolean {
        static_cast<Plugin *>(data)->registry->tick();
        return G_SOURCE_CONTINUE;
      },
      plugin, nullptr);
  // The registrar is temporary. Messenger channel handlers retain the plugin
  // until engine shutdown; neither the timer nor Plugin retains a channel.
}
