import sys
import subprocess
import json
import re

def get_displays():
    try:
        # We need the output from gdbus
        output = subprocess.check_output([
            "gdbus", "call", "--session",
            "--dest", "org.gnome.Mutter.DisplayConfig",
            "--object-path", "/org/gnome/Mutter/DisplayConfig",
            "--method", "org.gnome.Mutter.DisplayConfig.GetCurrentState"
        ], stderr=subprocess.STDOUT).decode('utf-8')
        
        # Look for the list of connectors: (('connector', 'vendor', 'product', ...), [modes], ...)
        pattern = r"\(\('([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)'\)"
        matches = re.findall(pattern, output)
        
        displays = []
        for match in matches:
            connector, vendor, product, _ = match
            displays.append({"connector": connector, "vendor": vendor, "product": product})
            
        return displays
    except Exception as e:
        return []

if __name__ == "__main__":
    displays = get_displays()
    for d in displays:
        print(f"{d['connector']}|{d['vendor']} {d['product']}")
