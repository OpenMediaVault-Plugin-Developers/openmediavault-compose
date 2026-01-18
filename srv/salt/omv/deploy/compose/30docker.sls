# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2022-2026 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.compose') %}
{% set nocterm = salt['pillar.get']('default:OMV_NO_CTERM_DEPENDENCY', 'no') | to_bool %}
{% set use_podman = config.podman | to_bool %}
{% set storage_path = (config.podmanStorage if use_podman else config.dockerStorage) %}
{% set create_config = (storage_path | default('') | length > 1) %}

{# systemd override file path based on runtime #}
{% set waitConf = ('/etc/systemd/system/podman.socket.d/waitAllMounts.conf'
                   if use_podman else
                   '/etc/systemd/system/docker.service.d/waitAllMounts.conf') %}

{# ---- Storage dir (shared) ---- #}
{% if create_config %}
container_storage_dir:
  file.directory:
    - name: "{{ storage_path }}"
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True
{% endif %}

{# ---- Runtime-specific install + config ---- #}
{% if use_podman %}

podman_install_packages:
  pkg.installed:
    - pkgs:
      - podman
      - podman-docker
      - aardvark-dns

{% if create_config %}
podman_storage_conf:
  file.managed:
    - name: /etc/containers/storage.conf
    - user: root
    - group: root
    - mode: "0644"
    - makedirs: True
    - contents: |
        [storage]
        driver = "overlay"
        graphroot = "{{ storage_path }}"
        runroot = "/run/containers/storage"


podman_socket_restart_on_config_change:
  service.running:
    - name: podman.socket
    - enable: True
    - watch:
      - file: podman_storage_conf
{% endif %}

/etc/containers/nodocker:
  file.touch

podman_docker_profile_sh_enable:
  file.rename:
    - source: /etc/profile.d/podman-docker.sh.disabled
    - name: /etc/profile.d/podman-docker.sh
    - force: True
    - onlyif:
      - test -f /etc/profile.d/podman-docker.sh.disabled

podman_docker_profile_csh_enable:
  file.rename:
    - source: /etc/profile.d/podman-docker.csh.disabled
    - name: /etc/profile.d/podman-docker.csh
    - force: True
    - onlyif:
      - test -f /etc/profile.d/podman-docker.csh.disabled

{% else %}

docker_install_packages:
  pkg.installed:
    - pkgs:
      - containerd.io
      - docker-ce
      - docker-ce-cli

{% if create_config %}
configure_etc_docker_dir:
  file.directory:
    - name: "/etc/docker"
    - user: "root"
    - group: "root"
    - mode: "0755"
    - makedirs: True

/etc/docker/daemon.json:
  file.serialize:
    - dataset:
        data-root: "{{ storage_path }}"
        storage-driver: "overlay2"
        {% if config.logmaxsize|int > 0 %}
        log-driver: "json-file"
        log-opts:
          max-size: "{{ config.logmaxsize }}m"
          max-file: "3"
        {% endif %}
        {% if config.liverestore %}
        live-restore: true
        {% endif %}
    - serializer: json
    - user: root
    - group: root
    - mode: "0600"

docker:
  service.running:
    - enable: True
    - watch:
      - file: /etc/docker/daemon.json
{% endif %}

podman_docker_profile_sh_disable:
  file.rename:
    - source: /etc/profile.d/podman-docker.sh
    - name: /etc/profile.d/podman-docker.sh.disabled
    - force: True
    - onlyif:
      - test -f /etc/profile.d/podman-docker.sh

podman_docker_profile_csh_disable:
  file.rename:
    - source: /etc/profile.d/podman-docker.csh
    - name: /etc/profile.d/podman-docker.csh.disabled
    - force: True
    - onlyif:
      - test -f /etc/profile.d/podman-docker.csh

{% endif %}

{# ---- Common packages ---- #}
common_install_packages:
  pkg.installed:
    - pkgs:
      - docker-compose-plugin
      - docker-buildx-plugin
      {% if not nocterm %}
      - openmediavault-cterm
      {% endif %}
    - require:
      {% if use_podman %}
      - pkg: podman_install_packages
      {% else %}
      - pkg: docker_install_packages
      {% endif %}

{# ---- Wait for /srv mounts override ---- #}
{% set mounts = salt['cmd.shell']('systemctl list-units --type=mount | awk \'$5 ~ "/srv" { printf "%s ",$1 }\'') %}

{{ waitConf }}:
  file.managed:
    - contents: |
        [Unit]
        After=local-fs.target {{ mounts }}
    - mode: "0644"
    - makedirs: True

systemd_daemon_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: {{ waitConf }}
