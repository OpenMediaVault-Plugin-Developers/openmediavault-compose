#!/usr/bin/env python3

# Copyright (c) 2025 openmediavault plugin developers
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# version: 1.1.0

from flask import Flask, render_template, request, session, redirect, url_for, jsonify
from flask_socketio import SocketIO, emit
import logging
import os, subprocess, pwd, grp, pty
import signal, sys, atexit
import threading
import configparser
import PAM
import termios, tty
import fcntl, struct, termios

# Load configuration
cfg = configparser.ConfigParser()
cfg.read("/etc/omv_compose_term.conf")

srv = cfg["server"]  # section proxy for [server]
HOST = srv.get("host", "0.0.0.0")
PORT = srv.getint("port", 5000)
DEBUG = srv.getboolean("debug", False)
USE_HTTPS = srv.getboolean("use_https", False)
SSL_CERT = srv.get("ssl_cert", None)
SSL_KEY = srv.get("ssl_key", None)
HOST_SHELL = srv.getboolean("host_shell", False)

def handle_sigterm(signum, frame):
    for termId, (master_fd, pid) in list(shells.items()):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass
        socketio.emit('terminal_exit', {}, room=termId)
    shells.clear()
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_sigterm)

# Initialize Flask and SocketIO using threading mode using threading mode
app = Flask(__name__)
app.secret_key = os.urandom(24)

logging.getLogger('werkzeug').setLevel(logging.WARNING)
logging.getLogger('engineio').setLevel(logging.WARNING)
logging.getLogger('socketio').setLevel(logging.WARNING)

socketio = SocketIO(app, async_mode='threading')

ALLOWED_GROUP = 'dockerterm'

# Change your shells mapping to store (master_fd, child_pid):
shells = {}  # sid -> (master_fd, child_pid)

def is_user_in_group(username, groupname):
    try:
        group = grp.getgrnam(groupname)
        return username in group.gr_mem or pwd.getpwnam(username).pw_gid == group.gr_gid
    except Exception:
        return False

def pam_authenticate(username, password):
    def pam_conv(auth, query_list, user_data):
        resp = []
        for query, q_type in query_list:
            if q_type in (PAM.PAM_PROMPT_ECHO_ON, PAM.PAM_PROMPT_ECHO_OFF):
                resp.append((password, 0))
            else:
                resp.append(("", 0))
        return resp
    pam = PAM.pam()
    pam.start("other")
    pam.set_item(PAM.PAM_USER, username)
    pam.set_item(PAM.PAM_CONV, pam_conv)
    try:
        pam.authenticate()
        pam.acct_mgmt()
        return True
    except Exception:
        return False

def get_containers():
    try:
        out = subprocess.check_output("docker container ls --format '{{.Names}}' | sort", shell=True)
        return [n for n in out.decode().splitlines() if n]
    except subprocess.CalledProcessError:
        return []

# Disable caching on all responses
@app.after_request
def after_request(response):
    response.headers.update({
        'Cache-Control': 'no-cache, no-store, must-revalidate, public, max-age=0',
        'Pragma': 'no-cache',
        'Expires': '0'
    })
    return response

# Routes
@app.route('/')
def index():
    container = request.args.get('container')
    if session.get('username'):
        return redirect(url_for('terminal', container=container, host_shell=HOST_SHELL)) if container else redirect(url_for('container_selection'))
    return render_template('login.html', container=container)

@app.route('/login', methods=['POST'])
def login():
    u = request.form.get('username')
    p = request.form.get('password')
    if not u or not p:
        return render_template('login.html', error='Username and password required')
    if not pam_authenticate(u, p):
        return render_template('login.html', error='Authentication failed')
    if not is_user_in_group(u, ALLOWED_GROUP):
        return render_template('login.html', error=f'Must be in {ALLOWED_GROUP} group')
    session['username'] = u
    c = request.form.get('container') or request.args.get('container')
    return redirect(url_for('terminal', container=c)) if c else redirect(url_for('container_selection'))

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('index'))

@app.route('/containers')
def container_selection():
    if not session.get('username'):
        return redirect(url_for('index'))
    return render_template('containers.html', containers=get_containers(), host_shell=HOST_SHELL)

@app.route('/terminal/<container>')
def terminal(container):
    if not session.get('username'):
        return redirect(url_for('index', container=container))
    if container == '__host__':
        if not HOST_SHELL:
            return render_template(
                'containers.html',
                error="Host Shell is disabled",
                containers=get_containers(),
                host_shell=HOST_SHELL
            )
        else:
            return render_template('terminal.html', container='__host__', host_shell=HOST_SHELL)
    try:
        subprocess.check_call(['docker', 'inspect', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return render_template('terminal.html', container=container, host_shell=HOST_SHELL)
    except subprocess.CalledProcessError:
        return render_template('containers.html', error=f"Container '{container}' not found", containers=get_containers(), host_shell=HOST_SHELL)

# PTY read loop
def read_and_emit(master_fd, sid):
    while True:
        try:
            data = os.read(master_fd, 1024)
            if not data:
                break
            socketio.emit('output', data.decode(errors='ignore'), to=sid)
        except OSError:
            break

    # once the loop ends, the shell has exited
    socketio.emit('terminal_exit', {}, to=sid)
    try:
        os.close(master_fd)
    except OSError:
        pass
    shells.pop(sid, None)

# Socket.IO handlers
@socketio.on('connect')
def on_connect():
    print('Client connected', request.sid)

@socketio.on('disconnect')
def on_disconnect():
    sid = request.sid
    entry = shells.pop(sid, None)
    if entry:
        master_fd, pid = entry
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        os.close(master_fd)
    print('Client disconnected', sid)

@socketio.on('start_terminal')
def start_terminal(data):
    container = data.get('container')
    sid = request.sid
    if container == '__host__' and not HOST_SHELL:
        emit('output', 'Error: Host shell is disabled\n')
        return
    if not container:
        emit('output', 'Error: No container specified\n')
        return
    if sid in shells:
        emit('output', f'[{container}]$ ')
        return
    pid, master_fd = pty.fork()
    if pid == 0:
        # In child: exec interactive shell
        env = os.environ.copy()
        env['TERM'] = data.get('termType','xterm')
        if container == '__host__':
            # Prepare environment and args
            username = session.get('username')
            pw = pwd.getpwnam(username)
            # Drop group privileges first
            os.setgid(pw.pw_gid)
            # Then user privileges
            os.setuid(pw.pw_uid)
            # Change working directory to the user's home
            home_dir = pw.pw_dir
            # if user's home doesn't exist, use /tmp
            if not os.path.isdir(home_dir):
                home_dir = '/tmp'
            # Change working directory
            os.chdir(home_dir)
            # Update HOME and user env vars
            env['HOME'] = pw.pw_dir
            env['PWD'] = pw.pw_dir
            env['USER'] = username
            env['LOGNAME'] = username
            env.pop('MAIL', None)
            # exec host bash
            args = ['--login', '-i']
            os.execvpe('bash', args, env)
        else:
            base_args = ['docker', 'exec', '-i', '-t', container]
            # Check if bash works
            check = subprocess.call(
                base_args + ['bash', '-c', 'exit 0'],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            if check == 0:
                args = base_args + ['bash', '--noprofile', '--norc', '-i']
            else:
                args = base_args + ['sh', '-i']
            os.execvpe('docker', args, env)
    else:
        tty.setraw(master_fd)
        if container == '__host__':
            import termios
            attrs = termios.tcgetattr(master_fd)
            attrs[3] |= termios.ECHO
            attrs[1] |= termios.OPOST | termios.ONLCR
            termios.tcsetattr(master_fd, termios.TCSADRAIN, attrs)

        shells[sid] = (master_fd, pid)
        threading.Thread(target=read_and_emit, args=(master_fd, sid), daemon=True).start()
        emit('output', f"Connected to {container}\r\n")

@socketio.on('terminal_input')
def terminal_input(data):
    sid = request.sid
    inp = data.get('input', '')
    entry = shells.get(sid)
    if entry:
        master_fd, child_pid = entry
        os.write(master_fd, inp.encode())
    else:
        emit('output', 'No shell session\n')
        import signal

@socketio.on('resize')
def resize(data):
    sid = request.sid
    entry = shells.get(sid)
    if not entry:
        return
    master_fd, child_pid = entry
    rows, cols = data['rows'], data['cols']
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)
    try:
        os.kill(child_pid, signal.SIGWINCH)
    except OSError:
        pass

@socketio.on('close_terminal')
def on_close_terminal(data):
    sid = request.sid
    entry = shells.pop(sid, None)
    if entry:
        master_fd, child_pid = entry
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass


if __name__ == '__main__':
    run_kwargs = dict(
        host=HOST,
        port=PORT,
        debug=DEBUG,
        allow_unsafe_werkzeug=True
    )
    if USE_HTTPS and SSL_CERT and SSL_KEY:
        run_kwargs['ssl_context'] = (SSL_CERT, SSL_KEY)
    socketio.run(app, **run_kwargs)
