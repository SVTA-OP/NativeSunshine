import sys
import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mutter_record_virtual.py <connector>")
        sys.exit(1)
        
    connector = sys.argv[1]
    
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    
    screencast_obj = bus.get_object('org.gnome.Mutter.ScreenCast', '/org/gnome/Mutter/ScreenCast')
    screencast_iface = dbus.Interface(screencast_obj, 'org.gnome.Mutter.ScreenCast')
    
    session_path = screencast_iface.CreateSession({})
    
    session_obj = bus.get_object('org.gnome.Mutter.ScreenCast', session_path)
    session_iface = dbus.Interface(session_obj, 'org.gnome.Mutter.ScreenCast.Session')
    
    try:
        stream_path = session_iface.RecordMonitor(connector, {
            'cursor-mode': dbus.UInt32(1)
        })
    except Exception as e:
        print(f"Error RecordMonitor: {e}")
        sys.exit(1)
    
    stream_obj = bus.get_object('org.gnome.Mutter.ScreenCast', stream_path)
    stream_iface = dbus.Interface(stream_obj, 'org.gnome.Mutter.ScreenCast.Stream')
    
    def on_stream_added(node_id):
        print(f"{node_id}")
        sys.stdout.flush()
        
    stream_iface.connect_to_signal("PipeWireStreamAdded", on_stream_added)
    session_iface.Start()
    
    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass

if __name__ == '__main__':
    main()
