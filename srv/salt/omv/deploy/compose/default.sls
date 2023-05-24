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
{% if config.sharedfolderref | length > 0 %}
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](config.sharedfolderref) %}

{% for file in config.files.file %}
{% set composeDir = sfpath ~ file.name %}
{% set composeFile = composeDir ~ '/' ~ file.name ~ '.yml' %}
{% set envFile = composeDir ~ '/' ~ file.name ~ '.env' %}

configure_compose_dir_{{ file.name }}:
  file.directory:
    - name: "{{ composeDir }}"
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

configure_compose_{{ file.name }}_file:
  file.managed:
    - name: '{{ composeFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_yml.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: root
    - group: users
    - mode: 644

configure_compose_env_{{ file.name }}_file:
  file.managed:
    - name: '{{ envFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_env_yml.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: root
    - group: users
    - mode: 644

{% endfor %}

{% for file in config.dockerfiles.dockerfile %}
{% set dockerfileDir = sfpath ~ file.name %}
{% set dockerFile = dockerfileDir ~ '/Dockerfile' %}

configure_compose_dir_{{ file.name }}:
  file.directory:
    - name: "{{ dockerfileDir }}"
    - user: root
    - group: root
    - mode: 755
    - makedirs: True


configure_dockerfile_{{ dockerFile }}:
  file.managed:
    - name: '{{ dockerFile }}'
    - source:
      - salt://{{ tpldir }}/files/dockerfile.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: root
    - group: users
    - mode: 644

{% if file.script | length > 0 %}
{% set scriptFile = dockerfileDir ~ '/' ~ file.script %}

configure_dockerfile_script_{{ scriptFile }}:
  file.managed:
    - name: '{{ scriptFile }}'
    - source:
      - salt://{{ tpldir }}/files/dockerfile_script.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: root
    - group: users
    - mode: 644

{% endif %}

{% if file.conf | length > 0 %}
{% set confFile = dockerfileDir ~ '/' ~ file.conf %}

configure_dockerfile_conf_{{ confFile }}:
  file.managed:
    - name: '{{ confFile }}'
    - source:
      - salt://{{ tpldir }}/files/dockerfile_conf.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: root
    - group: users
    - mode: 644

{% endif %}

{% endfor %}
{% endif %}

{% set omvextras = salt['omv_conf.get']('conf.system.omvextras') %}
{% set arch = grains['osarch'] %}
{% set docker = omvextras.docker %}

{% if docker | to_bool and not arch == 'i386' %}
{% set docker_pkg = "docker-ce" %}
{% set compose_pkg = "docker-compose-plugin" %}
{% else %}
{% set docker_pkg = "docker.io" %}
{% set compose_pkg = "docker-compose" %}
{% endif %}

docker_install_packages:
  pkg.installed:
    - pkgs:
      - "{{ docker_pkg }}"
      - "{{ compose_pkg }}"
{% if docker | to_bool and not arch == 'i386' %}
      - containerd.io
      - docker-ce-cli
{% endif %}

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

{% endif %}

docker:
  service.running:
    - reload: True
    - enable: True
    - watch:
        - file: /etc/docker/daemon.json


download_autocompose:
  file.managed:
    - name: /usr/bin/autocompose.py
    - source: https://github.com/Red5d/docker-autocompose/raw/master/autocompose.py
    - user: root
    - group: root
    - mode: 755
    - skip_verify: True
