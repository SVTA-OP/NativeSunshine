#!/usr/bin/env bash
# =============================================================================
# lib/display.sh — Virtual display verification and PipeWire node discovery
#
# Your virtual display is created at login via:
#   /usr/bin/gnome-shell --mode=user --virtual-monitor 800x1340
# (configured in ~/.config/systemd/user/org.gnome.Shell@user.service.d/)
#
# This module does NOT create or destroy the display — it verifies the display
# is live and finds its PipeWire node ID for GStreamer capture.
# =============================================================================

# Exported after verify_virtual_display():
#   VIRT_DISPLAY_NAME   — e.g. "Virtual-1" or "HEADLESS-1"
#   VIRT_PW_NODE_ID     — numeric PipeWire node ID for pipewiresrc

# -----------------------------------------------------------------------------
# verify_virtual_display — confirm the virtual monitor is present in Mutter.
# Uses the org.gnome.Mutter.DisplayConfig D-Bus interface to list outputs.
# Sets VIRT_DISPLAY_NAME on success.
# -----------------------------------------------------------------------------
verify_virtual_display() {
    log_step "Verifying virtual display (${TARGET_WIDTH}x${TARGET_HEIGHT})"

    # Query Mutter's DisplayConfig for current monitors
    local monitors_json
    monitors_json=$(gdbus call --session \
        --dest org.gnome.Mutter.DisplayConfig \
        --object-path /org/gnome/Mutter/DisplayConfig \
        --method org.gnome.Mutter.DisplayConfig.GetCurrentState \
        2>/dev/null) || {
            log_error "Failed to query org.gnome.Mutter.DisplayConfig.GetCurrentState"
            log_error "Is GNOME Shell running on this Wayland session?"
            return 1
        }

    # Parse connector names from the GVariant output.
    # The output contains connector strings; virtual monitors are reported as
    # "Virtual-N" by Mutter (from --virtual-monitor flag).
    local virt_name
    virt_name=$(echo "$monitors_json" | grep -oP "'Virtual-\d+'" | head -1 | tr -d "'")

    if [[ -z "$virt_name" ]]; then
        # GNOME 42+ names virtual monitors Meta-0, Meta-1, etc.
        virt_name=$(echo "$monitors_json" | grep -oP "'Meta-\d+'" | head -1 | tr -d "'")
    fi

    if [[ -z "$virt_name" ]]; then
        # Fallback: try HEADLESS- prefix (older Mutter versions)
        virt_name=$(echo "$monitors_json" | grep -oP "'HEADLESS-\d+'" | head -1 | tr -d "'")
    fi

    if [[ -z "$virt_name" ]]; then
        log_error "No virtual display found in Mutter's display list."
        log_error "Expected a 'Virtual-N' output from --virtual-monitor ${TARGET_WIDTH}x${TARGET_HEIGHT}."
        log_error "Check your systemd override:"
        log_error "  cat ~/.config/systemd/user/org.gnome.Shell@user.service.d/persistent-virtual-monitor.conf"
        log_error "Then verify with: gnome-randr (if installed) or check GNOME display settings."
        return 1
    fi

    export VIRT_DISPLAY_NAME="$virt_name"
    log_success "Virtual display found: ${VIRT_DISPLAY_NAME}"
    return 0
}

# -----------------------------------------------------------------------------
# get_pipewire_node_id — find the PipeWire node ID for the virtual display.
#
# When GNOME Shell's --virtual-monitor is active, Mutter's ScreenCast backend
# exposes it as a PipeWire source node. We identify it via pw-dump by matching
# the node's "port.alias" or "node.description" against the virtual display name.
# -----------------------------------------------------------------------------
get_pipewire_node_id() {
    log_step "Discovering PipeWire node for ${VIRT_DISPLAY_NAME:-virtual display}"

    # pw-dump outputs a JSON array of all PipeWire objects.
    # We look for nodes of type "PipeWire:Interface:Node" that are video sources
    # from gnome-shell (the compositor exposes monitor captures as PW nodes).

    local pw_json
    pw_json=$(pw-dump 2>/dev/null) || die "pw-dump failed — is PipeWire running?"

    # Strategy 1: match by node.description containing the virtual display name
    local node_id
    node_id=$(echo "$pw_json" | jq -r --arg name "${VIRT_DISPLAY_NAME}" '
        .[] |
        select(.type == "PipeWire:Interface:Node") |
        select(
            (.info.props["node.description"] // "" | test($name; "i")) or
            (.info.props["port.alias"] // "" | test($name; "i")) or
            (.info.props["node.name"] // "" | test($name; "i"))
        ) |
        select(.info.props["media.class"] // "" | test("Video/Source"; "i")) |
        .id
    ' 2>/dev/null | head -1)

    # Strategy 2: if no match on display name, look for gnome-shell video sources
    # and pick the one matching our resolution
    if [[ -z "$node_id" ]]; then
        log_warn "No PipeWire node matched '${VIRT_DISPLAY_NAME}' by name — trying resolution match..."
        node_id=$(echo "$pw_json" | jq -r --argjson w "${TARGET_WIDTH}" --argjson h "${TARGET_HEIGHT}" '
            .[] |
            select(.type == "PipeWire:Interface:Node") |
            select(.info.props["media.class"] // "" | test("Video/Source"; "i")) |
            select(
                (.info.props["node.description"] // "" | test("gnome-shell|mutter|compositor|screen|monitor"; "i")) or
                (.info.props["application.name"] // "" | test("gnome-shell|mutter"; "i"))
            ) |
            # Try to filter by resolution if format info is available
            .id
        ' 2>/dev/null | head -1)
    fi

    # Strategy 3: XDG Desktop Portal ScreenCast node (fallback)
    # When the portal creates a screencast session it also registers a PW node.
    # We prompt for a screencast session if strategies 1+2 fail.
    if [[ -z "$node_id" ]]; then
        log_warn "Automatic PipeWire node discovery failed."
        log_info "Falling back to native headless Mutter ScreenCast API..."
        node_id=$(_get_pw_node_headless "$VIRT_DISPLAY_NAME") || return 1
    fi

    if [[ -z "$node_id" ]] || ! [[ "$node_id" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine PipeWire node ID for the virtual display."
        log_error "Run 'pw-dump | jq '.[] | select(.type==\"PipeWire:Interface:Node\") | {id, desc: .info.props[\"node.description\"]}'' to list nodes."
        return 1
    fi

    export VIRT_PW_NODE_ID="$node_id"
    log_success "PipeWire node ID: ${VIRT_PW_NODE_ID}"
    return 0
}

_get_pw_node_headless() {
    local connector="$1"
    # Do NOT use log_info here because this function's stdout is captured by $(...)

    # Create a temporary file for the python script output
    local out_file="/tmp/ns_mutter_out"
    rm -f "$out_file"
    
    # Run the script in the background
    python3 "${SCRIPT_DIR}/lib/mutter_record_virtual.py" "$connector" > "$out_file" &
    export MUTTER_SCREENCAST_PID=$!
    
    # Wait up to 5 seconds for the node ID
    local i
    for i in {1..50}; do
        if [[ -s "$out_file" ]]; then
            local node_id
            node_id=$(cat "$out_file")
            if [[ "$node_id" =~ ^[0-9]+$ ]]; then
                echo "$node_id"
                rm -f "$out_file"
                return 0
            fi
        fi
        sleep 0.1
    done
    
    echo "Failed to get PipeWire node ID from headless screencast." >&2
    rm -f "$out_file"
    kill "$MUTTER_SCREENCAST_PID" 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# display_info — print a human-readable summary of the virtual display state.
# -----------------------------------------------------------------------------
display_info() {
    log_info "Virtual display: ${VIRT_DISPLAY_NAME:-<unknown>} @ ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}Hz"
    log_info "PipeWire node:   ${VIRT_PW_NODE_ID:-<unknown>}"
}
