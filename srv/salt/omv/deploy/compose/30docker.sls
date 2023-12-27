# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2022-2023 OpenMediaVault Plugin Developers
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

# create daemon.json file if docker storage path is specified
{% if config.dockerStorage | length > 1 %}

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
        data-root: "{{ config.dockerStorage }}"
    - serializer: json
    - user: root
    - group: root
    - mode: "0600"

{% endif %}

docker_install_packages:
  pkg.installed:
    - pkgs:
      - docker-ce

docker_compose_install_packages:
  pkg.installed:
    - pkgs:
      - docker-compose-plugin
      - containerd.io
      - docker-ce-cli
      - docker-buildx-plugin

docker_purged_packages:
  pkg.purged:
    - pkgs:
      - docker-compose

{% if config.dockerStorage | length > 1 %}

docker:
  service.running:
    - enable: True
    - watch:
      - file: /etc/docker/daemon.json

{% endif %}

{% set mounts = salt['cmd.shell']('systemctl list-units --type=mount | awk \'$5 ~ "/srv" { printf "%s ",$1 }\'') %}
{% set waitConf = '/etc/systemd/system/docker.service.d/waitAllMounts.conf' %}

{{ waitConf }}:
  file.managed:
    - contents: |
        [Unit]
        After=local-fs.target {{ mounts }}
    - mode: "0644"
    - makedirs: True

systemd_daemon_reload_docker:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: {{ waitConf }}

create_usr_local_bin_dir:
  file.directory:
    - name: "/usr/local/bin"
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True

/usr/local/bin/docker-compose:
  file.symlink:
    - target: /usr/libexec/docker/cli-plugins/docker-compose
    - force: True
