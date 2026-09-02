#!/usr/bin/env python3
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw, Gio, GLib
import json
import os
import subprocess
import signal

CONFIG_DIR = os.path.expanduser("~/.config/native-sunshine")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
MAIN_SCRIPT = os.path.join(SCRIPT_DIR, "native-sunshine.sh")

class NativeSunshineApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id='dev.nativesunshine.Gui')
        self.config = self.load_config()
        self.stream_process = None

    def load_config(self):
        default_config = {
            "encoder": "vulkan",
            "bitrate": 8000,
            "keyframe_interval": 60,
            "resolution_scale": 100,
            "placement": "right"
        }
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, 'r') as f:
                    config = json.load(f)
                    default_config.update(config)
            except Exception as e:
                print(f"Error loading config: {e}")
        return default_config

    def save_config(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        try:
            with open(CONFIG_FILE, 'w') as f:
                json.dump(self.config, f, indent=4)
        except Exception as e:
            print(f"Error saving config: {e}")

    def do_activate(self):
        win = Adw.ApplicationWindow(application=self, title="Native Sunshine")
        win.set_default_size(500, 600)

        # Main box
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        
        # Header bar
        header = Adw.HeaderBar()
        main_box.append(header)

        # Settings page
        page = Adw.PreferencesPage()
        main_box.append(page)

        # Stream Settings Group
        group_stream = Adw.PreferencesGroup(title="Stream Settings")
        page.add(group_stream)

        # Encoder combo
        self.encoder_model = Gtk.StringList.new(["vulkan", "vaapi", "nvenc", "software"])
        self.encoder_combo = Adw.ComboRow(title="Hardware Encoder", model=self.encoder_model)
        
        # Set active encoder
        try:
            active_idx = ["vulkan", "vaapi", "nvenc", "software"].index(self.config.get("encoder", "vulkan"))
            self.encoder_combo.set_selected(active_idx)
        except ValueError:
            self.encoder_combo.set_selected(0)
            
        self.encoder_combo.connect("notify::selected", self.on_encoder_changed)
        group_stream.add(self.encoder_combo)

        # Bitrate spin button
        self.bitrate_adj = Gtk.Adjustment(value=self.config.get("bitrate", 8000), lower=1000, upper=50000, step_increment=500)
        self.bitrate_spin = Gtk.SpinButton(adjustment=self.bitrate_adj, numeric=True)
        self.bitrate_spin.set_valign(Gtk.Align.CENTER)
        self.bitrate_spin.connect("value-changed", self.on_bitrate_changed)
        bitrate_row = Adw.ActionRow(title="Bitrate (kbps)")
        bitrate_row.add_suffix(self.bitrate_spin)
        group_stream.add(bitrate_row)


        # Keyframe interval spin button
        self.keyframe_adj = Gtk.Adjustment(value=self.config.get("keyframe_interval", 60), lower=10, upper=300, step_increment=10)
        self.keyframe_spin = Gtk.SpinButton(adjustment=self.keyframe_adj, numeric=True)
        self.keyframe_spin.set_valign(Gtk.Align.CENTER)
        self.keyframe_spin.connect("value-changed", self.on_keyframe_changed)
        keyframe_row = Adw.ActionRow(title="Keyframe Interval (frames)")
        keyframe_row.add_suffix(self.keyframe_spin)
        group_stream.add(keyframe_row)

        # Resolution scale spin button / knob
        self.scale_adj = Gtk.Adjustment(value=self.config.get("resolution_scale", 100), lower=10, upper=100, step_increment=5)
        self.scale_spin = Gtk.SpinButton(adjustment=self.scale_adj, numeric=True)
        self.scale_spin.set_valign(Gtk.Align.CENTER)
        self.scale_spin.connect("value-changed", self.on_scale_changed)
        scale_row = Adw.ActionRow(title="Resolution Scale (%)", subtitle="Lower to reduce decode latency")
        scale_row.add_suffix(self.scale_spin)
        group_stream.add(scale_row)

        # Monitor Settings Group
        group_monitor = Adw.PreferencesGroup(title="Virtual Monitor Settings")
        page.add(group_monitor)

        # Placement combo
        self.placement_options = ["right", "left", "above", "below"]
        placement_labels = ["Right of Main Display", "Left of Main Display", "Above Main Display", "Below Main Display"]
        self.placement_model = Gtk.StringList.new(placement_labels)
        self.placement_combo = Adw.ComboRow(title="Placement", model=self.placement_model)
        
        try:
            active_idx = self.placement_options.index(self.config.get("placement", "right"))
            self.placement_combo.set_selected(active_idx)
        except ValueError:
            self.placement_combo.set_selected(0)
            
        self.placement_combo.connect("notify::selected", self.on_placement_changed)
        group_monitor.add(self.placement_combo)

        # Launch Button
        self.launch_btn = Gtk.Button(label="Launch Stream")
        self.launch_btn.add_css_class("suggested-action")
        self.launch_btn.add_css_class("pill")
        self.launch_btn.set_halign(Gtk.Align.CENTER)
        self.launch_btn.set_margin_top(20)
        self.launch_btn.set_margin_bottom(20)
        self.launch_btn.connect("clicked", self.on_launch_clicked)
        
        main_box.append(self.launch_btn)

        # Telemetry Group (hidden by default)
        self.telemetry_group = Adw.PreferencesGroup(title="Hardware Telemetry (Live)")
        self.telemetry_group.set_visible(False)
        page.add(self.telemetry_group)

        self.telemetry_max_fps = Adw.ActionRow(title="Max Decoder FPS")
        self.telemetry_max_fps.add_suffix(Gtk.Label(label="--"))
        self.telemetry_group.add(self.telemetry_max_fps)

        self.telemetry_refresh = Adw.ActionRow(title="Display Refresh Rate")
        self.telemetry_refresh.add_suffix(Gtk.Label(label="--"))
        self.telemetry_group.add(self.telemetry_refresh)

        self.telemetry_low_latency = Adw.ActionRow(title="Low-Latency API Support")
        self.telemetry_low_latency.add_suffix(Gtk.Label(label="--"))
        self.telemetry_group.add(self.telemetry_low_latency)

        self.telemetry_timer = None

        win.set_content(main_box)
        win.present()

    def on_encoder_changed(self, combo, pspec):
        selected_item = combo.get_selected_item()
        if selected_item:
            self.config["encoder"] = selected_item.get_string()
            self.save_config()

    def on_bitrate_changed(self, spin):
        self.config["bitrate"] = int(spin.get_value())
        self.save_config()


    def on_keyframe_changed(self, spin):
        self.config["keyframe_interval"] = int(spin.get_value())
        self.save_config()

    def on_scale_changed(self, spin):
        self.config["resolution_scale"] = int(spin.get_value())
        self.save_config()

    def on_placement_changed(self, combo, pspec):
        idx = combo.get_selected()
        if idx < len(self.placement_options):
            self.config["placement"] = self.placement_options[idx]
            self.save_config()

    def on_launch_clicked(self, btn):
        if self.stream_process and self.stream_process.poll() is None:
            # Stop the stream
            self.stream_process.send_signal(signal.SIGINT)
            self.stream_process.wait()
            self.stream_process = None
            self.launch_btn.set_label("Launch Stream")
            self.launch_btn.remove_css_class("destructive-action")
            self.launch_btn.add_css_class("suggested-action")
            self.telemetry_group.set_visible(False)
            if self.telemetry_timer:
                GLib.source_remove(self.telemetry_timer)
                self.telemetry_timer = None
        else:
            # Start the stream
            # Clean up old telemetry file
            if os.path.exists("/tmp/native-sunshine-telemetry.json"):
                os.remove("/tmp/native-sunshine-telemetry.json")
            
            # ensure native-sunshine.sh is executable
            os.chmod(MAIN_SCRIPT, 0o755)
            self.stream_process = subprocess.Popen([MAIN_SCRIPT])
            self.launch_btn.set_label("Stop Stream")
            self.launch_btn.remove_css_class("suggested-action")
            self.launch_btn.add_css_class("destructive-action")
            
            # Watch process and telemetry
            GLib.timeout_add(1000, self.check_process_status)
            self.telemetry_timer = GLib.timeout_add(500, self.poll_telemetry)

    def poll_telemetry(self):
        telemetry_file = "/tmp/native-sunshine-telemetry.json"
        if os.path.exists(telemetry_file):
            try:
                with open(telemetry_file, 'r') as f:
                    data = json.load(f)
                    self.telemetry_max_fps.set_subtitle(f"{data.get('maxFps', '--')} fps")
                    self.telemetry_refresh.set_subtitle(f"{data.get('refreshRate', '--')} Hz")
                    self.telemetry_low_latency.set_subtitle("Yes" if data.get('lowLatency', 'false') == "true" else "No")
                    self.telemetry_group.set_visible(True)
            except Exception:
                pass
            return False # Stop polling once found
        return True # Keep polling

    def check_process_status(self):
        if self.stream_process and self.stream_process.poll() is not None:
            self.stream_process = None
            self.launch_btn.set_label("Launch Stream")
            self.launch_btn.remove_css_class("destructive-action")
            self.launch_btn.add_css_class("suggested-action")
            self.telemetry_group.set_visible(False)
            if self.telemetry_timer:
                GLib.source_remove(self.telemetry_timer)
                self.telemetry_timer = None
            return False
        return True

if __name__ == '__main__':
    app = NativeSunshineApp()
    app.run(None)
