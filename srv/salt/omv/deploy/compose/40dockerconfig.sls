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
{% set mounts = salt['cmd.shell']('systemctl list-units --type=mount | awk \'$5 ~ "/srv" { printf "%s ",$1 }\'') %}

/etc/systemd/system/docker.service.d/waitAllMounts.conf:
  file.managed:
    - contents: |
        [Unit]
        After=local-fs.target {{ mounts }}
    - mode: "0644"
    - makedirs: True

systemd_daemon_reload_docker:
  cmd.run:
    - name: systemctl daemon-reload

# create daemon.json file if docker storage path is specified
{% if config.dockerStorage | length > 1 %}

/etc/docker/daemon.json:
  file.serialize:
    - dataset:
        data-root: "{{ config.dockerStorage }}"
    - serializer: json
    - user: root
    - group: root
    - mode: "0600"

docker:
  service.running:
    - reload: True
    - enable: True
    - watch:
        - file: /etc/docker/daemon.json

{% endif %}
