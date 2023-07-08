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
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](config.sharedfolderref).rstrip('/') %}

{% for file in config.dockerfiles.dockerfile %}
{% set dockerfileDir = sfpath ~ file.name %}
{% set dockerFile = dockerfileDir ~ '/Dockerfile' %}

configure_compose_dir_{{ file.name }}:
  file.directory:
    - name: "{{ dockerfileDir }}"
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.mode }}"
    - makedirs: True

configure_dockerfile_{{ dockerFile }}:
  file.managed:
    - name: '{{ dockerFile }}'
    - source:
      - salt://{{ tpldir }}/files/dockerfile.j2
    - context:
        file: {{ file | json }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

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
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

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
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% endif %}

{% endfor %}
{% endif %}
