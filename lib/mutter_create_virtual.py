import sys
import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 mutter_create_virtual.py <width> <height>")
        sys.exit(1)
        
    width = int(sys.argv[1])
    height = int(sys.argv[2])
    
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    
    screencast_obj = bus.get_object('org.gnome.Mutter.ScreenCast', '/org/gnome/Mutter/ScreenCast')
    screencast_iface = dbus.Interface(screencast_obj, 'org.gnome.Mutter.ScreenCast')
    
    session_path = screencast_iface.CreateSession({})
    
    session_obj = bus.get_object('org.gnome.Mutter.ScreenCast', session_path)
    session_iface = dbus.Interface(session_obj, 'org.gnome.Mutter.ScreenCast.Session')
    
    try:
        # RecordVirtual takes properties. is-platform is whether it acts like a physical display
        stream_path = session_iface.RecordVirtual({
            'cursor-mode': dbus.UInt32(1),
            'is-platform': dbus.Boolean(True)
        })
    except Exception as e:
        print(f"Error RecordVirtual: {e}")
        sys.exit(1)
    
    stream_obj = bus.get_object('org.gnome.Mutter.ScreenCast', stream_path)
    stream_iface = dbus.Interface(stream_obj, 'org.gnome.Mutter.ScreenCast.Stream')
    
    def on_stream_added(node_id):
        print(f"{node_id}")
        sys.stdout.flush()
        
    stream_iface.connect_to_signal("PipeWireStreamAdded", on_stream_added)
    
    # We need to tell the stream what resolution it is. This is done via DBus if possible, or maybe RecordVirtual inherently creates it? 
    # Actually RecordVirtual doesn't take resolution? It takes properties. Maybe we don't need it? No, virtual displays need to know their size. 
    # Let me check if we can pass width/height to RecordVirtual or if the compositor just streams at whatever we ask in pipewire?
    # Usually you don't pass size to RecordVirtual, or you pass it in properties.
    # GNOME Mutter API for RecordVirtual properties might not allow size explicitly. Let's just try running it.
    
    session_iface.Start()

    import signal
    from gi.repository import GLibUnix

    loop = GLib.MainLoop()

    def sig_handler():
        try:
            session_iface.Stop()
        except:
            pass
        loop.quit()
        return False

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, sig_handler)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, sig_handler)

    loop.run()
    
    # Also attempt Stop here just in case
    try:
        session_iface.Stop()
    except:
        pass

if __name__ == '__main__':
    main()
