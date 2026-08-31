import sys
import os
import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

def main():
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    
    # Get Mutter ScreenCast interface
    screencast_obj = bus.get_object('org.gnome.Mutter.ScreenCast', '/org/gnome/Mutter/ScreenCast')
    screencast_iface = dbus.Interface(screencast_obj, 'org.gnome.Mutter.ScreenCast')
    
    # Create Session
    session_path = screencast_iface.CreateSession({})
    
    session_obj = bus.get_object('org.gnome.Mutter.ScreenCast', session_path)
    session_iface = dbus.Interface(session_obj, 'org.gnome.Mutter.ScreenCast.Session')
    
    # Record Monitor (Meta-0)
    # The signature for RecordMonitor is (sa{sv}) -> o
    # monitor connector, properties
    try:
        stream_path = session_iface.RecordMonitor('Meta-0', {})
        print(f"STREAM:{stream_path}")
    except Exception as e:
        print(f"Error recording monitor: {e}")
        sys.exit(1)

    # Start Session
    session_iface.Start()
    
    stream_obj = bus.get_object('org.gnome.Mutter.ScreenCast', stream_path)
    stream_iface = dbus.Interface(stream_obj, 'org.gnome.Mutter.ScreenCast.Stream')
    
    # The stream exposes a PipeWire node ID via a property
    props_iface = dbus.Interface(stream_obj, 'org.freedesktop.DBus.Properties')
    node_id = props_iface.Get('org.gnome.Mutter.ScreenCast.Stream', 'PipeWireNodeId')
    print(f"NODE_ID:{node_id}")

    # To keep the stream alive, we'd normally run the main loop
    # GLib.MainLoop().run()
    
if __name__ == '__main__':
    main()
