#!/usr/bin/env python3
import sys
try:
    import dbus
except ModuleNotFoundError:
    import os
    if sys.executable != '/usr/bin/python3' and os.path.exists('/usr/bin/python3'):
        os.execv('/usr/bin/python3', ['/usr/bin/python3'] + sys.argv)
    raise

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 placement_manager.py [left|right|above|below|disable|current] [orientation] [scale_percent]")
        sys.exit(1)
        
    placement = sys.argv[1].lower()
    target_orientation = int(sys.argv[2]) if len(sys.argv) >= 3 else 0
    target_scale_pct = float(sys.argv[3]) if len(sys.argv) >= 4 else None

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
                    if mode[6].get('is-current', False):
                        return mode[0], mode[1], mode[2]
                for mode in modes:
                    if mode[6].get('is-preferred', False):
                        return mode[0], mode[1], mode[2]
                if modes:
                    return modes[0][0], modes[0][1], modes[0][2]
        return "", 1920, 1080

    def get_supported_scales(connector):
        for m in monitors:
            m_info, modes, m_props = m
            if m_info[0] == connector:
                for mode in modes:
                    if mode[6].get('is-current') or mode[6].get('is-preferred'):
                        return [float(s) for s in mode[5]]
                if modes:
                    return [float(s) for s in modes[0][5]]
        return [1.0]

    if target_scale_pct is not None:
        target_val = target_scale_pct / 100.0
        supported = get_supported_scales(virtual_connector)
        chosen_scale = min(supported, key=lambda s: abs(s - target_val))
    else:
        chosen_scale = None

    if not virtual_lm:
        if placement == "disable":
            print("Virtual monitor is already disabled.")
            sys.exit(0)
            
        # The virtual monitor exists but is disabled (not in logical layout).
        # We append a default logical monitor for it so it gets enabled.
        virtual_lm = (0, 0, 1.0, target_orientation, False, [(virtual_connector, "", {})], {})
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
    if chosen_scale is not None:
        vscale = chosen_scale

    def get_lm_box(lm):
        conn = lm[5][0][0]
        mode_id, w_raw, h_raw = get_active_mode_id_and_size(conn)
        if lm[3] in (1, 3):
            w_raw, h_raw = h_raw, w_raw
        s = float(lm[2])
        return lm[0], lm[1], int(round(w_raw / s)), int(round(h_raw / s))

    other_lms = [lm for lm in logical_monitors if lm != virtual_lm]
    boxes = [get_lm_box(lm) for lm in other_lms] if other_lms else [get_lm_box(primary_lm)]

    p_mode_id, p_width_raw, p_height_raw = get_active_mode_id_and_size(plinked[0][0])
    if ptransform in (1, 3):
        p_width_raw, p_height_raw = p_height_raw, p_width_raw
    p_width = int(round(p_width_raw / pscale))
    p_height = int(round(p_height_raw / pscale))
    
    v_mode_id, v_width_raw, v_height_raw = get_active_mode_id_and_size(vlinked[0][0])
    if target_orientation in (1, 3):
        v_width_raw, v_height_raw = v_height_raw, v_width_raw
    v_width = int(round(v_width_raw / vscale))
    v_height = int(round(v_height_raw / vscale))

    nx, ny = vx, vy
    if placement == "right":
        nx = max(b[0] + b[2] for b in boxes)
        ny = py
    elif placement == "left":
        nx = min(b[0] for b in boxes) - v_width
        ny = py
    elif placement == "above":
        nx = px
        ny = min(b[1] for b in boxes) - v_height
    elif placement == "below":
        nx = px
        ny = max(b[1] + b[3] for b in boxes)
    elif placement == "current":
        nx = vx
        ny = vy

    def try_apply_config(candidate_x, candidate_y):
        min_x = min([candidate_x] + [lm[0] for lm in other_lms])
        min_y = min([candidate_y] + [lm[1] for lm in other_lms])
        x_offset = -min_x
        y_offset = -min_y

        new_logical_monitors = []
        for lm in other_lms:
            lx, ly, lscale, ltransform, lprimary, llinked, lprops = lm
            new_logical_monitors.append((dbus.Int32(lx + x_offset), dbus.Int32(ly + y_offset), lscale, ltransform, lprimary, llinked))
        new_logical_monitors.append((dbus.Int32(candidate_x + x_offset), dbus.Int32(candidate_y + y_offset), dbus.Double(vscale), dbus.UInt32(target_orientation), dbus.Boolean(False), vlinked))

        formatted_logical_monitors = []
        for x, y, scale, trans, prim, linked in new_logical_monitors:
            formatted_linked = []
            for link in linked:
                connector = link[0]
                mode_id, _, _ = get_active_mode_id_and_size(connector)
                formatted_linked.append((dbus.String(connector), dbus.String(mode_id), dbus.Dictionary({}, signature='sv')))
            formatted_logical_monitors.append((dbus.Int32(x), dbus.Int32(y), dbus.Double(scale), dbus.UInt32(trans), dbus.Boolean(prim), formatted_linked))

        iface.ApplyMonitorsConfig(serial, 1, formatted_logical_monitors, properties)

    applied = False
    for offset in [0, 1, -1, 2, -2]:
        try:
            try_apply_config(nx + offset, ny)
            applied = True
            print(f"Applied virtual monitor placement: {placement} (scale: {vscale})")
            break
        except Exception as e:
            last_err = e

    if not applied:
        print(f"Failed to apply monitor config: {last_err}")

if __name__ == '__main__':
    main()
