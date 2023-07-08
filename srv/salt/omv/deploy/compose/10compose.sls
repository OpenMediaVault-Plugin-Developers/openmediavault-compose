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
{% set datapath = "" %}
{% if config.datasharedfolderref | string | length > 1 %}
{% set datapath = salt['omv_conf.get_sharedfolder_path'](config.datasharedfolderref) %}
{% if not salt['file.directory_exists'](datapath) %}
{% set datapath = "" %}
{% endif %}
{% endif %}

{% for file in config.files.file %}
{% set composeDir = sfpath ~ file.name %}
{% set composeFile = composeDir ~ '/' ~ file.name ~ '.yml' %}
{% set envFile = composeDir ~ '/' ~ file.name ~ '.env' %}

configure_compose_dir_{{ file.name }}:
  file.directory:
    - name: "{{ composeDir }}"
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.mode }}"
    - makedirs: True

configure_compose_{{ file.name }}_file:
  file.managed:
    - name: '{{ composeFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_yml.j2
    - context:
        file: {{ file | json }}
        datapath: {{ datapath }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

configure_compose_env_{{ file.name }}_file:
  file.managed:
    - name: '{{ envFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_env_yml.j2
    - context:
        file: {{ file | json }}
        datapath: {{ datapath }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% endfor %}
{% endif %}
