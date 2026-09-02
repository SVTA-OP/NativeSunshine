#!/usr/bin/env python3
import sys
import dbus

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 placement_manager.py [left|right|above|below|disable]")
        sys.exit(1)
        
    placement = sys.argv[1].lower()

    bus = dbus.SessionBus()
    
    try:
        obj = bus.get_object('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig')
        iface = dbus.Interface(obj, 'org.gnome.Mutter.DisplayConfig')
        
        # GetCurrentState returns:
        # serial, monitors, logical_monitors, properties
        serial, monitors, logical_monitors, properties = iface.GetCurrentState()
    except Exception as e:
        print(f"Error connecting to DisplayConfig: {e}")
        sys.exit(1)

    # find primary monitor to get anchor coords
    primary_lm = None
    virtual_lm = None
    virtual_connector = None
    
    # First find the virtual monitor in the raw physical monitors list
    for m in monitors:
        connector = m[0][0]
        if "Virtual" in connector or "HEADLESS" in connector or "Meta" in connector:
            virtual_connector = connector
            break

    if not virtual_connector:
        print("Virtual monitor not found in monitors.")
        sys.exit(1)

    for lm in logical_monitors:
        x, y, scale, transform, primary, linked_monitors, props = lm
        for m in linked_monitors:
            if m[0] == virtual_connector:
                virtual_lm = lm
                break
        if primary:
            primary_lm = lm

    def get_active_mode_id_and_size(connector):
        for m in monitors:
            m_info, modes, m_props = m
            if m_info[0] == connector:
                for mode in modes:
                    if 'is-current' in mode[6] and mode[6]['is-current']:
                        return mode[0], mode[1], mode[2]
                for mode in modes:
                    if 'is-preferred' in mode[6] and mode[6]['is-preferred']:
                        return mode[0], mode[1], mode[2]
                if modes:
                    return modes[0][0], modes[0][1], modes[0][2]
        return "", 1920, 1080

    if not virtual_lm:
        if placement == "disable":
            print("Virtual monitor is already disabled.")
            sys.exit(0)
            
        # The virtual monitor exists but is disabled (not in logical layout).
        # We append a default logical monitor for it so it gets enabled.
        virtual_lm = (0, 0, 1.0, 0, False, [(virtual_connector, "", {})], {})
        # Note: logical_monitors is a dbus.Array, we can just append to a list copy or directly use it
        logical_monitors = list(logical_monitors)
        logical_monitors.append(virtual_lm)
    elif placement == "disable":
        # Remove it from logical monitors to disable it
        logical_monitors = [lm for lm in logical_monitors if lm != virtual_lm]
        
        # We must shift the remaining monitors so the bounding box starts at (0,0)
        if logical_monitors:
            min_x = min([lm[0] for lm in logical_monitors])
            min_y = min([lm[1] for lm in logical_monitors])
        else:
            min_x, min_y = 0, 0
            
        new_logical_monitors = []
        for lx, ly, lscale, ltransform, lprimary, llinked, lprops in logical_monitors:
            new_logical_monitors.append((dbus.Int32(lx - min_x), dbus.Int32(ly - min_y), lscale, ltransform, lprimary, llinked))
            
        try:
            formatted_logical_monitors = []
            for x, y, scale, trans, prim, linked in new_logical_monitors:
                formatted_linked = []
                for link in linked:
                    connector = link[0]
                    mode_id, _, _ = get_active_mode_id_and_size(connector)
                    formatted_linked.append((dbus.String(connector), dbus.String(mode_id), dbus.Dictionary({}, signature='sv')))
                formatted_logical_monitors.append((dbus.Int32(x), dbus.Int32(y), dbus.Double(scale), dbus.UInt32(trans), dbus.Boolean(prim), formatted_linked))
    
            iface.ApplyMonitorsConfig(serial, 1, formatted_logical_monitors, properties)
            print("Virtual monitor disabled.")
        except Exception as e:
            print(f"Failed to disable monitor: {e}")
        sys.exit(0)

    if not primary_lm:
        # fallback to the first non-virtual monitor
        for lm in logical_monitors:
            if lm != virtual_lm:
                primary_lm = lm
                break
                
    if not primary_lm:
        print("No primary monitor found.")
        sys.exit(1)

    # Calculate new x, y for virtual monitor
    px, py, pscale, ptransform, pprimary, plinked, pprops = primary_lm
    vx, vy, vscale, vtransform, vprimary, vlinked, vprops = virtual_lm
    
    # We need the physical dimensions of the primary monitor
    # We can get it from logical_monitors or properties. Let's assume logical width/height are derived from properties or just use common sense.
    # Actually, the logical monitor doesn't explicitly store width/height in the top level of the tuple.
    # It stores (x, y, scale, transform, primary, linked_monitors_array, properties)
    # How to get width/height of logical monitor? It is determined by the linked monitor modes.
    
    # Let's just find the max x, y to append, or calculate it.
    # A simpler way is to find the bounding box of the primary monitor.
    # For now, let's look up the mode of the linked monitor.
    
    p_mode_id, p_width_raw, p_height_raw = get_active_mode_id_and_size(plinked[0][0])
    p_width = int(p_width_raw / pscale)
    p_height = int(p_height_raw / pscale)
    
    v_mode_id, v_width_raw, v_height_raw = get_active_mode_id_and_size(vlinked[0][0])
    v_width = int(v_width_raw / vscale)
    v_height = int(v_height_raw / vscale)

    nx, ny = vx, vy
    if placement == "right":
        nx = px + p_width
        ny = py
    elif placement == "left":
        nx = px - v_width
        ny = py
    elif placement == "above":
        nx = px
        ny = py - v_height
    elif placement == "below":
        nx = px
        ny = py + p_height

    min_x = min([nx] + [lm[0] for lm in logical_monitors if lm != virtual_lm])
    min_y = min([ny] + [lm[1] for lm in logical_monitors if lm != virtual_lm])
    
    x_offset = -min_x if min_x < 0 else 0
    y_offset = -min_y if min_y < 0 else 0

    # Reconstruct logical_monitors array for ApplyMonitorsConfig
    new_logical_monitors = []
    for lm in logical_monitors:
        lx, ly, lscale, ltransform, lprimary, llinked, lprops = lm
        if lm == virtual_lm:
            new_logical_monitors.append((dbus.Int32(nx + x_offset), dbus.Int32(ny + y_offset), lscale, ltransform, lprimary, llinked))
        else:
            new_logical_monitors.append((dbus.Int32(lx + x_offset), dbus.Int32(ly + y_offset), lscale, ltransform, lprimary, llinked))

    # Apply configuration (method 1 = apply)
    try:
        # signature is 'uua(iiuduasa{sv})a{sv}'
        # Actually ApplyMonitorsConfig expects (x, y, scale, transform, primary, linked) without properties dict
        # wait, the linked array expects (connector, mode_id, properties)
        formatted_logical_monitors = []
        for x, y, scale, trans, prim, linked in new_logical_monitors:
            formatted_linked = []
            for link in linked:
                connector = link[0]
                mode_id, _, _ = get_active_mode_id_and_size(connector)
                formatted_linked.append((dbus.String(connector), dbus.String(mode_id), dbus.Dictionary({}, signature='sv')))
            formatted_logical_monitors.append((dbus.Int32(x), dbus.Int32(y), dbus.Double(scale), dbus.UInt32(trans), dbus.Boolean(prim), formatted_linked))

        iface.ApplyMonitorsConfig(serial, 1, formatted_logical_monitors, properties)
        print(f"Applied virtual monitor placement: {placement}")
    except Exception as e:
        print(f"Failed to apply monitor config: {e}")

if __name__ == '__main__':
    main()
