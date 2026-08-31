import dbus

def main():
    bus = dbus.SessionBus()
    proxy = bus.get_object('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig')
    iface = dbus.Interface(proxy, 'org.gnome.Mutter.DisplayConfig')
    
    state = iface.GetCurrentState()
    # state is a tuple: (serial, physical_monitors, logical_monitors, properties)
    serial, physical_monitors, logical_monitors, properties = state
    
    print("Logical Monitors:")
    for i, lm in enumerate(logical_monitors):
        print(f"  [{i}]: {lm}")

    print("\nPhysical Monitors:")
    for i, pm in enumerate(physical_monitors):
        print(f"  [{i}]: {pm}")

if __name__ == '__main__':
    main()
