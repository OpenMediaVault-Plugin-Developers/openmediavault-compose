from flask import Flask, render_template, request, session, redirect, url_for, jsonify, send_from_directory
from flask_socketio import SocketIO, emit
import os, subprocess, pwd, grp
from urllib.parse import urlparse, urlunparse
import configparser
import json
import PAM

cfg = configparser.ConfigParser()
cfg.read("/etc/omv-compose-term.conf")

srv = cfg["server"]
HOST = srv.get("host", "0.0.0.0")
PORT = srv.getint("port", 5000)
DEBUG = srv.getboolean("debug", False)
USE_HTTPS = srv.getboolean("use_https", False)
SSL_CERT = srv.get("ssl_cert", None)
SSL_KEY = srv.get("ssl_key", None)

# Initialize Flask app and SocketIO
app = Flask(__name__)
app.secret_key = os.urandom(24)
socketio = SocketIO(app)

ALLOWED_GROUP = 'dockerterm'

def is_user_in_group(username, groupname):
    try:
        group = grp.getgrnam(groupname)
        return username in group.gr_mem or pwd.getpwnam(username).pw_gid == group.gr_gid
    except KeyError:
        return False

def pam_authenticate(username, password):
    def pam_conv(auth, query_list, user_data):
        resp = []
        for query, q_type in query_list:
            if q_type in (PAM.PAM_PROMPT_ECHO_ON, PAM.PAM_PROMPT_ECHO_OFF):
                resp.append((password, 0))
            elif q_type == PAM.PAM_TEXT_INFO:
                resp.append(('', 0))
            elif q_type == PAM.PAM_ERROR_MSG:
                resp.append(('', 0))
        return resp

    pam = PAM.pam()
    pam.start("other")
    pam.set_item(PAM.PAM_USER, username)
    pam.set_item(PAM.PAM_CONV, pam_conv)
    try:
        pam.authenticate()
        pam.acct_mgmt()
        return True
    except PAM.error:
        return False

def get_containers():
    try:
        cmd = "docker ps --format '{{.Names}}'"
        result = subprocess.check_output(cmd, shell=True).decode('utf-8')
        containers = [name for name in result.strip().split('\n') if name]
    except subprocess.CalledProcessError:
        containers = []
    return containers

@app.route("/")
def index():
    container = request.args.get("container")
    if "username" in session:
        if container:
            return redirect(url_for("terminal", container=container))
        return redirect(url_for("container_selection"))
    return render_template("login.html", container=container)

@app.route("/login", methods=["POST"])
def login():
    if request.is_json:
        # Handle API login requests (JSON)
        data = request.get_json()
        username = data.get("username")
        password = data.get("password")
    else:
        # Handle form-based login
        username = request.form.get("username")
        password = request.form.get("password")
    
    if not username or not password:
        if request.is_json:
            return jsonify({"error": "Missing username or password"}), 400
        return render_template("login.html", error="Please provide both username and password")

    if not pam_authenticate(username, password):
        if request.is_json:
            return jsonify({"error": "Authentication failed"}), 401
        return render_template("login.html", error="Invalid username or password")
    
    if not is_user_in_group(username, ALLOWED_GROUP):
        if request.is_json:
            return jsonify({"error": "Unauthorized"}), 403
        return render_template("login.html", error=f"You need to be a member of the {ALLOWED_GROUP} group")
    
    session["username"] = username
    container = request.form.get('container') or request.args.get('container')
    if container:
        session['container'] = container
        return redirect(url_for('terminal', container=container))
    else:
        return redirect(url_for('container_selection'))

@app.route("/logout")
def logout():
    session.pop("username", None)
    return redirect(url_for('index'))

@app.route("/containers")
def container_selection():
    if "username" not in session:
        return redirect(url_for('index'))
    
    containers = get_containers()
    return render_template("containers.html", containers=containers)

@app.route("/terminal/<container>")
def terminal(container):
    if "username" not in session:
        return redirect(url_for('index', container=container))

    # Verify the container exists before rendering the terminal page
    try:
        check_cmd = ["docker", "inspect", container]
        subprocess.check_call(check_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return render_template("terminal.html", container=container)
    except subprocess.CalledProcessError:
        return render_template("containers.html", 
                               error=f"Container '{container}' does not exist or is not running",
                               containers=get_containers())

# Socket.IO event handlers
@socketio.on("connect")
def connect():
    print(f"Client connected: {request.sid}")

@socketio.on("disconnect")
def disconnect():
    print(f"Client disconnected: {request.sid}")

@socketio.on("start_terminal")
def start_terminal(data):
    if "username" not in session:
        emit("output", "Not authenticated. Please log in.\n")
        return
    
    container = data.get("container")
    if not container:
        emit("output", "Error: No container specified\n")
        return
    
    print(f"Starting terminal for container: {container}")
    
    # Check if container exists and is running
    try:
        # Check if container exists
        check_cmd = ["docker", "inspect", "--format", "{{.State.Running}}", container]
        running = subprocess.check_output(check_cmd, text=True).strip()
        
        if running != "true":
            emit("output", f"Error: Container '{container}' exists but is not running\n")
            return
        
        # Get container information
        container_info_cmd = ["docker", "inspect", "--format", "{{.Config.Image}} (ID: {{.Id}})", container]
        container_info = subprocess.check_output(container_info_cmd, text=True).strip()
        
        # Welcome message with container verification
        welcome_msg = (f"[{container}]$ ")
        
        emit("output", welcome_msg)
        print(f"Terminal started for container {container}")
        
    except subprocess.CalledProcessError as e:
        emit("output", f"Error: Container '{container}' does not exist or cannot be accessed.\n")
        print(f"Failed to start terminal for container {container}: {e}")
    except Exception as e:
        emit("output", f"Unexpected error: {str(e)}\n")
        print(f"Exception in start_terminal: {e}")

@socketio.on("terminal_input")
def terminal_input(data):
    if "username" not in session:
        emit("output", "Not authenticated. Please log in.\n")
        return
    
    container = data.get("container")
    input_text = data.get("input")
    
    if not container:
        emit("output", "Error: No container specified\n")
        return
    
    if not input_text:
        emit("output", f"[{container}]$ ")
        return
    
    print(f"Executing in {container}: {input_text}")
    
    try:
        # Try to execute with bash first
        shell = "bash"
        cmd = ["docker", "exec", container, shell, "-c", input_text]
        
        try:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = process.communicate(timeout=30)
            
            if process.returncode != 0 and "executable file not found" in stderr:
                # Fall back to sh if bash is not available
                shell = "sh"
                cmd = ["docker", "exec", container, shell, "-c", input_text]
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                stdout, stderr = process.communicate(timeout=30)
            
            # Send output to client
            if stdout:
                emit("output", stdout)
            if stderr:
                emit("output", stderr)
            
        except subprocess.TimeoutExpired:
            process.kill()
            emit("output", "Command timed out after 30 seconds\n")
        
        # Always show prompt after command execution
        emit("output", f"\r\n[{container}]$ ")
        
    except Exception as e:
        emit("output", f"Error executing command: {str(e)}\r\n[{container}]$ ")
        print(f"Exception in terminal_input: {e}")

if __name__ == "__main__":
    if USE_HTTPS:
        socketio.run(
            app,
            host=HOST,
            port=PORT,
            debug=DEBUG,
            use_reloader=DEBUG,
            certfile=SSL_CERT,
            keyfile=SSL_KEY
        )
    else:
        socketio.run(
            app,
            host=HOST,
            port=PORT,
            debug=DEBUG,
            use_reloader=DEBUG
        )
