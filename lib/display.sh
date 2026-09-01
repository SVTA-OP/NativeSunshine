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
# verify_virtual_display — (Deprecated) kept for compatibility.
# -----------------------------------------------------------------------------
verify_virtual_display() {
    # If TARGET_DISPLAY is virtual, we will create it dynamically.
    if [[ "${TARGET_DISPLAY:-virtual}" == "virtual" ]]; then
        export VIRT_DISPLAY_NAME="Dynamic Virtual Monitor"
        return 0
    else
        export VIRT_DISPLAY_NAME="${TARGET_DISPLAY}"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# get_pipewire_node_id — find the PipeWire node ID for the target display.
# -----------------------------------------------------------------------------
get_pipewire_node_id() {
    log_step "Discovering PipeWire node for ${VIRT_DISPLAY_NAME}"
    local node_id
    
    if [[ "${TARGET_DISPLAY:-virtual}" == "virtual" ]]; then
        log_info "Creating dynamic virtual monitor (${TARGET_WIDTH}x${TARGET_HEIGHT})..."
        node_id=$(_create_pw_node_virtual "$TARGET_WIDTH" "$TARGET_HEIGHT") || return 1
    else
        log_info "Recording existing display ${TARGET_DISPLAY}..."
        node_id=$(_get_pw_node_headless "$TARGET_DISPLAY") || return 1
    fi
    
    if [[ -z "$node_id" ]] || ! [[ "$node_id" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine PipeWire node ID for the display."
        return 1
    fi

    export VIRT_PW_NODE_ID="$node_id"
    log_success "PipeWire node ID: ${VIRT_PW_NODE_ID}"
    return 0
}

_create_pw_node_virtual() {
    local w="$1"
    local h="$2"
    local out_file="/tmp/ns_mutter_out"
    rm -f "$out_file"
    
    python3 "${SCRIPT_DIR}/lib/mutter_create_virtual.py" "$w" "$h" > "$out_file" &
    export MUTTER_SCREENCAST_PID=$!
    
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
    
    echo "Failed to get PipeWire node ID from virtual screencast." >&2
    rm -f "$out_file"
    kill "$MUTTER_SCREENCAST_PID" 2>/dev/null || true
    return 1
}

_get_pw_node_headless() {
    local connector="$1"
    local out_file="/tmp/ns_mutter_out"
    rm -f "$out_file"
    
    python3 "${SCRIPT_DIR}/lib/mutter_record_virtual.py" "$connector" > "$out_file" &
    export MUTTER_SCREENCAST_PID=$!
    
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
