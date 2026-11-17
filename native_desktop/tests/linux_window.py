"""Normal X11 teardown for an owned acceptance-test window."""
import ctypes


def delete_window(identifier):
    # Send the window manager's normal close request; GTK then tears down the
    # Flutter engine and its plugin messenger handlers in their normal order.
    class Data(ctypes.Union):
        _fields_ = [('b', ctypes.c_char * 20), ('s', ctypes.c_short * 10),
                    ('l', ctypes.c_long * 5)]

    class Message(ctypes.Structure):
        _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                    ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                    ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                    ('format', ctypes.c_int), ('data', Data)]

    class Event(ctypes.Union):
        _fields_ = [('message', Message), ('padding', ctypes.c_long * 24)]

    x11 = ctypes.CDLL('libX11.so.6')
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_long, ctypes.POINTER(Event)]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError('Cannot open owned X11 display')
    try:
        event = Event()
        event.message.type = 33
        event.message.send_event = 1
        event.message.display = display
        event.message.window = int(identifier)
        event.message.message_type = x11.XInternAtom(display, b'WM_PROTOCOLS', 0)
        event.message.format = 32
        event.message.data.l[0] = x11.XInternAtom(display, b'WM_DELETE_WINDOW', 0)
        if not x11.XSendEvent(display, int(identifier), 0, 0, ctypes.byref(event)):
            raise RuntimeError('WM_DELETE_WINDOW send failed')
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)
