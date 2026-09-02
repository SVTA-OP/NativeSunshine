import socket
import json
import os
import signal
import sys

# Listen for control messages on port 7879
HOST = '127.0.0.1'
PORT = 7879

GUI_CONFIG_FILE = os.path.expanduser("~/.config/native-sunshine/config.json")

def load_gui_config():
    if os.path.exists(GUI_CONFIG_FILE):
        try:
            with open(GUI_CONFIG_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def save_gui_config(config):
    os.makedirs(os.path.dirname(GUI_CONFIG_FILE), exist_ok=True)
    with open(GUI_CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=4)

def kill_port(port):
    """Kill any process holding the given port so we can bind cleanly."""
    try:
        import subprocess
        result = subprocess.run(
            ['fuser', '-k', f'{port}/tcp'],
            capture_output=True, timeout=2
        )
    except Exception:
        pass

def main():
    if len(sys.argv) > 1:
        parent_pid = int(sys.argv[1])
    else:
        parent_pid = None

    # Kill any stale instance holding our port before binding
    kill_port(PORT)
    import time; time.sleep(0.1)  # brief pause for kernel to release the port

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except AttributeError:
        pass  # SO_REUSEPORT not available on all platforms
    s.bind((HOST, PORT))
    s.listen(1)

    print(f"Control server listening on {PORT}")

    while True:
        try:
            conn, addr = s.accept()
            with conn:
                data = conn.recv(1024)
                if not data:
                    continue
                try:
                    msg = json.loads(data.decode('utf-8'))
                    print(f"Received control msg: {msg}")

                    # Handle Android-side errors
                    if "error" in msg:
                        print(f"\n[ERROR FROM ANDROID] {msg['error']}\n")
                        continue

                    # Load current config and check what actually changed
                    config = load_gui_config()
                    updated = False

                    if "bitrate" in msg:
                        new_val = int(msg["bitrate"])
                        if config.get("bitrate") != new_val:
                            print(f"Bitrate changed: {config.get('bitrate')} → {new_val}")
                            config["bitrate"] = new_val
                            updated = True

                    if "fps" in msg:
                        new_val = int(msg["fps"])
                        if config.get("framerate") != new_val:
                            print(f"Framerate changed: {config.get('framerate')} → {new_val}")
                            config["framerate"] = new_val
                            updated = True

                    if updated:
                        save_gui_config(config)
                        print("Settings changed — signaling parent to restart pipeline")
                        if parent_pid:
                            os.kill(parent_pid, signal.SIGUSR1)
                    else:
                        print("Settings unchanged — no restart needed")

                except Exception as e:
                    print(f"Error parsing control msg: {e}")
        except Exception as e:
            print(f"Server error: {e}")
            break

if __name__ == "__main__":
    main()
