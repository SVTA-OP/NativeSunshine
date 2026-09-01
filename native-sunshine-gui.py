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
            "framerate": 0,
            "keyframe_interval": 60,
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

        # Framerate spin button
        self.framerate_adj = Gtk.Adjustment(value=self.config.get("framerate", 0), lower=0, upper=240, step_increment=30)
        self.framerate_spin = Gtk.SpinButton(adjustment=self.framerate_adj, numeric=True)
        self.framerate_spin.set_valign(Gtk.Align.CENTER)
        self.framerate_spin.connect("value-changed", self.on_framerate_changed)
        framerate_row = Adw.ActionRow(title="Framerate (0 = Auto)")
        framerate_row.add_suffix(self.framerate_spin)
        group_stream.add(framerate_row)

        # Keyframe interval spin button
        self.keyframe_adj = Gtk.Adjustment(value=self.config.get("keyframe_interval", 60), lower=10, upper=300, step_increment=10)
        self.keyframe_spin = Gtk.SpinButton(adjustment=self.keyframe_adj, numeric=True)
        self.keyframe_spin.set_valign(Gtk.Align.CENTER)
        self.keyframe_spin.connect("value-changed", self.on_keyframe_changed)
        keyframe_row = Adw.ActionRow(title="Keyframe Interval (frames)")
        keyframe_row.add_suffix(self.keyframe_spin)
        group_stream.add(keyframe_row)

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

    def on_framerate_changed(self, spin):
        self.config["framerate"] = int(spin.get_value())
        self.save_config()

    def on_keyframe_changed(self, spin):
        self.config["keyframe_interval"] = int(spin.get_value())
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
        else:
            # Start the stream
            # ensure native-sunshine.sh is executable
            os.chmod(MAIN_SCRIPT, 0o755)
            self.stream_process = subprocess.Popen([MAIN_SCRIPT])
            self.launch_btn.set_label("Stop Stream")
            self.launch_btn.remove_css_class("suggested-action")
            self.launch_btn.add_css_class("destructive-action")
            
            # Watch process
            GLib.timeout_add(1000, self.check_process_status)

    def check_process_status(self):
        if self.stream_process and self.stream_process.poll() is not None:
            self.stream_process = None
            self.launch_btn.set_label("Launch Stream")
            self.launch_btn.remove_css_class("destructive-action")
            self.launch_btn.add_css_class("suggested-action")
            return False
        return True

if __name__ == '__main__':
    app = NativeSunshineApp()
    app.run(None)
