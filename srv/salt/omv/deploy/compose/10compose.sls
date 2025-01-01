# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2022-2025 openmediavault plugin developers
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
{% set datapath = "" %}
{% if config.datasharedfolderref | string | length > 1 %}
{% set datapath = salt['omv_conf.get_sharedfolder_path'](config.datasharedfolderref).rstrip('/') %}
{% if not salt['file.directory_exists'](datapath) %}
{% set datapath = "" %}
{% endif %}
{% endif %}

{% for file in config.files.file %}
{% set composeDir = sfpath ~ '/' ~ file.name %}
{% set composeFile = composeDir ~ '/' ~ file.name ~ '.yml' %}
{% set overrideFile = composeDir ~ '/compose.override.yml' %}
{% set envFile = composeDir ~ '/' ~ file.name ~ '.env' %}

configure_compose_file_dir_{{ file.name }}:
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

configure_compose_{{ file.name }}_override:
  file.managed:
    - name: '{{ overrideFile }}'
    - source:
      - salt://{{ tpldir }}/files/override_yml.j2
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

{%- for cnf in config.configs.config | selectattr("fileref", "equalto", file.uuid) %}

{% set cnfFile = composeDir ~ '/' ~ cnf.name %}

configure_compose_{{ file.name }}_config_{{ cnf.uuid }}:
  file.managed:
    - name: '{{ cnfFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_cnf.j2
    - context:
        file: {{ cnf | json }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% endfor %}
{% endfor %}

{% set globalenv = salt['omv_conf.get']('conf.service.compose.globalenv') %}
{% set globalEnvFile = sfpath ~ '/global.env' %}

{% if globalenv.enabled | to_bool %}

configure_compose_global_env_file:
  file.managed:
    - name: '{{ globalEnvFile }}'
    - source:
      - salt://{{ tpldir }}/files/global_env_yml.j2
    - context:
        globalenv: {{ globalenv | json }}
        datapath: {{ datapath }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% else %}

{% set datapath = "" %}
remove_compose_global_env_file:
  file.absent:
    - name: '{{ globalEnvFile }}'

{% endif %}
{% endif %}
