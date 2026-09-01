import socket
import json
import os
import signal
import sys

# Listen for control messages on port 7879
HOST = '127.0.0.1'
PORT = 7879
CONFIG_FILE = os.path.join(os.path.dirname(__file__), '..', 'config.sh')

def update_config(key, value):
    os.system(f"sed -i 's/^{key}=.*/{key}={value}/' {CONFIG_FILE}")

def main():
    if len(sys.argv) > 1:
        parent_pid = int(sys.argv[1])
    else:
        parent_pid = None
        
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
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
                    updated = False
                    if "bitrate" in msg:
                        update_config("STREAM_BITRATE", msg["bitrate"])
                        updated = True
                    if "fps" in msg:
                        update_config("TARGET_REFRESH", msg["fps"])
                        updated = True
                        
                    if updated and parent_pid:
                        # Send SIGUSR1 to parent (native-sunshine.sh) to restart pipeline
                        print("Settings updated, signaling parent to restart pipeline")
                        os.kill(parent_pid, signal.SIGUSR1)
                except Exception as e:
                    print(f"Error parsing control msg: {e}")
        except Exception as e:
            print(f"Server error: {e}")
            break

if __name__ == "__main__":
    main()
