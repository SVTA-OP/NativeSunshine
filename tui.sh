#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

source "$CONFIG_FILE"

# Ensure TARGET_DISPLAY exists in config.sh
if ! grep -q "^TARGET_DISPLAY=" "$CONFIG_FILE"; then
    echo "TARGET_DISPLAY=virtual" >> "$CONFIG_FILE"
    TARGET_DISPLAY=virtual
fi

update_config() {
    local key="$1"
    local val="$2"
    sed -i "s/^${key}=.*/${key}=${val}/" "$CONFIG_FILE"
}

show_main_menu() {
    while true; do
        source "$CONFIG_FILE"
        
        local display_desc="${TARGET_DISPLAY}"
        if [[ "$TARGET_DISPLAY" == "virtual" ]]; then
            display_desc="Virtual Screen (${TARGET_WIDTH}x${TARGET_HEIGHT})"
        fi
        
        CHOICE=$(whiptail --title "NativeSunshine Configuration" --menu "Select an option:" 20 70 10 \
            "1" "Start Stream" \
            "2" "Select Display (Current: $display_desc)" \
            "3" "Encoder (Current: $ENCODER)" \
            "4" "Bitrate (Current: $STREAM_BITRATE kbps)" \
            "5" "Virtual Resolution (Current: ${TARGET_WIDTH}x${TARGET_HEIGHT})" \
            "6" "FPS (Current: $TARGET_REFRESH)" \
            "7" "Port (Current: $ADB_STREAM_PORT)" \
            "8" "Exit" 3>&1 1>&2 2>&3)
            
        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            break
        fi
        
        case $CHOICE in
            1)
                clear
                "${SCRIPT_DIR}/native-sunshine.sh"
                break
                ;;
            2)
                # Select Display
                DISPLAYS=$(python3 "${SCRIPT_DIR}/lib/get_displays.py")
                MENU_ARGS=()
                MENU_ARGS+=("virtual" "Dynamic Virtual Monitor")
                while IFS='|' read -r connector desc; do
                    if [[ -n "$connector" ]]; then
                        MENU_ARGS+=("$connector" "$desc")
                    fi
                done <<< "$DISPLAYS"
                
                DISP=$(whiptail --title "Select Display" --menu "Choose display to stream:" 20 60 10 "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    update_config "TARGET_DISPLAY" "$DISP"
                fi
                ;;
            3)
                ENC=$(whiptail --title "Select Encoder" --menu "Choose hardware encoder:" 15 50 4 \
                    "vulkan" "AMD Vulkan (RADV)" \
                    "vaapi" "Intel/AMD VAAPI" \
                    "nvenc" "NVIDIA NVENC" \
                    "software" "CPU x264 (Fallback)" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    update_config "ENCODER" "$ENC"
                fi
                ;;
            4)
                BIT=$(whiptail --title "Bitrate" --inputbox "Enter bitrate in kbps:" 10 40 "$STREAM_BITRATE" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [[ "$BIT" =~ ^[0-9]+$ ]]; then
                    update_config "STREAM_BITRATE" "$BIT"
                fi
                ;;
            5)
                RES=$(whiptail --title "Virtual Resolution" --inputbox "Enter resolution (WxH):" 10 40 "${TARGET_WIDTH}x${TARGET_HEIGHT}" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [[ "$RES" =~ ^[0-9]+x[0-9]+$ ]]; then
                    W=$(echo "$RES" | cut -d'x' -f1)
                    H=$(echo "$RES" | cut -d'x' -f2)
                    update_config "TARGET_WIDTH" "$W"
                    update_config "TARGET_HEIGHT" "$H"
                fi
                ;;
            6)
                FPS=$(whiptail --title "FPS" --inputbox "Enter target FPS:" 10 40 "$TARGET_REFRESH" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [[ "$FPS" =~ ^[0-9]+$ ]]; then
                    update_config "TARGET_REFRESH" "$FPS"
                fi
                ;;
            7)
                PORT=$(whiptail --title "Port" --inputbox "Enter ADB stream port:" 10 40 "$ADB_STREAM_PORT" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
                    update_config "ADB_STREAM_PORT" "$PORT"
                fi
                ;;
            8)
                break
                ;;
        esac
    done
}

show_main_menu
clear
