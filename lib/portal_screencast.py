import sys
from gi.repository import GLib, Gio

def on_start_response(connection, sender_name, object_path, interface_name, signal_name, parameters, user_data):
    response, results = parameters
    if response == 0:
        node_id = results.get('streams', {}).get('a(ua{sv})', [])
        # The result 'streams' is an array of (node_id, dict)
        if 'streams' in results:
            streams = results['streams']
            for stream in streams:
                print(f"NODE_ID:{stream[0]}")
                sys.exit(0)
    print("Failed to start screencast")
    sys.exit(1)

def on_select_response(connection, sender_name, object_path, interface_name, signal_name, parameters, user_data):
    response, results = parameters
    if response != 0:
        print("User cancelled or selection failed")
        sys.exit(1)
    
    # Start the session
    bus = user_data['bus']
    session_handle = user_data['session_handle']
    request_token = "ns_start"
    
    bus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "Start",
        GLib.Variant("(oa{sv})", (session_handle, {"handle_token": GLib.Variant("s", request_token)})),
        GLib.VariantType("(o)"),
        Gio.DBusCallFlags.NONE,
        -1,
        None,
        None,
        None
    )
    
    bus.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        f"/org/freedesktop/portal/desktop/request/{user_data['sender_id']}/{request_token}",
        None,
        Gio.DBusSignalFlags.NO_MATCH_RULE,
        on_start_response,
        user_data
    )

def on_session_created(connection, sender_name, object_path, interface_name, signal_name, parameters, user_data):
    response, results = parameters
    if response != 0:
        print("Failed to create session")
        sys.exit(1)
        
    session_handle = results['session_handle']
    user_data['session_handle'] = session_handle
    bus = user_data['bus']
    
    request_token = "ns_select"
    bus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "SelectSources",
        GLib.Variant("(oa{sv})", (
            session_handle, 
            {
                "handle_token": GLib.Variant("s", request_token),
                "types": GLib.Variant("u", 1), # 1 = MONITOR
                "multiple": GLib.Variant("b", False)
            }
        )),
        GLib.VariantType("(o)"),
        Gio.DBusCallFlags.NONE,
        -1,
        None,
        None,
        None
    )
    
    bus.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        f"/org/freedesktop/portal/desktop/request/{user_data['sender_id']}/{request_token}",
        None,
        Gio.DBusSignalFlags.NO_MATCH_RULE,
        on_select_response,
        user_data
    )

def main():
    loop = GLib.MainLoop()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    
    # Get unique bus name and format for object path
    unique_name = bus.get_unique_name()
    sender_id = unique_name[1:].replace('.', '_')
    
    request_token = "ns_session"
    
    user_data = {
        'bus': bus,
        'sender_id': sender_id,
        'loop': loop
    }
    
    # Subscribe to session creation response
    bus.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        f"/org/freedesktop/portal/desktop/request/{sender_id}/{request_token}",
        None,
        Gio.DBusSignalFlags.NO_MATCH_RULE,
        on_session_created,
        user_data
    )
    
    # Call CreateSession
    bus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "CreateSession",
        GLib.Variant("(a{sv})", ({
            "handle_token": GLib.Variant("s", request_token),
            "session_handle_token": GLib.Variant("s", "ns_session_token")
        },)),
        GLib.VariantType("(o)"),
        Gio.DBusCallFlags.NONE,
        -1,
        None,
        None,
        None
    )
    
    loop.run()

if __name__ == '__main__':
    main()
