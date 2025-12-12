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

{% set sf_list = salt['omv_conf.get']('conf.system.sharedfolder') %}
{% set sfmap = {} %}
{% for sf in sf_list %}
  {% set name = sf.name %}
  {% set uuid = sf.uuid %}
  {% set path = salt['omv_conf.get_sharedfolder_path'](uuid).rstrip('/') %}
  {% do sfmap.update({name: path}) %}
{% endfor %}

{%- set uidmap = {} -%}
{%- set uent = salt['user.getent']() -%}

{%- for info in uent -%}
  {%- if info is mapping -%}
    {%- set uname = info.get('name') -%}
    {%- set uid = info.get('uid') -%}
    {%- if uname and uid is not none -%}
      {%- do uidmap.update({(uname|string): (uid|string)}) -%}
    {%- endif -%}
  {%- endif -%}
{%- endfor -%}

{%- set gidmap = {} -%}
{%- set gent = salt['group.getent']() -%}

{%- for info in gent -%}
  {%- if info is mapping -%}
    {%- set gname = info.get('name') -%}
    {%- set gid = info.get('gid') -%}
    {%- if gname and gid is not none -%}
      {%- do gidmap.update({(gname|string): (gid|string)}) -%}
    {%- endif -%}
  {%- endif -%}
{%- endfor -%}

{%- set timezone = salt['timezone.get_zone']() -%}

{%- macro resolve_sf(body) -%}
  {%- if not body -%}
    {{ "" }}
  {%- else -%}
    {%- set ns = namespace(text=body) -%}
    {%- for name, path in sfmap.items() -%}
      {%- set placeholder = '${{ sf:"' ~ name ~ '" }}' -%}
      {%- set ns.text = ns.text | replace(placeholder, path) -%}
    {%- endfor -%}
    {{ ns.text }}
  {%- endif -%}
{%- endmacro -%}

{%- macro replace_uid_tokens(text) -%}
  {%- set ns = namespace(out=text) -%}
  {%- for part in ns.out.split('${{ uid:"') -%}
    {%- if loop.first -%}{%- continue -%}{%- endif -%}
    {%- set uname = part.split('" }}', 1)[0] if '" }}' in part else None -%}
    {%- if uname -%}
      {%- set uname = (uname|string).strip() -%}
      {%- set uid = uidmap.get(uname) -%}
      {%- if uid is not none -%}
        {%- set ns.out = ns.out | replace('${{ uid:"' ~ uname ~ '" }}', uid|string) -%}
      {%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {{ ns.out }}
{%- endmacro -%}

{%- macro replace_gid_tokens(text) -%}
  {%- set ns = namespace(out=text) -%}
  {%- for part in ns.out.split('${{ gid:"') -%}
    {%- if loop.first -%}{%- continue -%}{%- endif -%}
    {%- set gname = part.split('" }}', 1)[0] if '" }}' in part else None -%}
    {%- if gname -%}
      {%- set gname = (gname|string).strip() -%}
      {%- set gid = gidmap.get(gname) -%}
      {%- if gid is not none -%}
        {%- set ns.out = ns.out | replace('${{ gid:"' ~ gname ~ '" }}', gid|string) -%}
      {%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {{ ns.out }}
{%- endmacro -%}

{%- macro render_body(raw, name, datapath) -%}
  {%- if not raw -%}
    {{ "" }}
  {%- else -%}
    {%- set b = resolve_sf(raw) -%}
    {%- set b = b | replace("CHANGE_TO_COMPOSE_NAME", name) -%}
    {%- if datapath is not none and datapath|length > 0 -%}
      {%- set b = b | replace("CHANGE_TO_COMPOSE_DATA_PATH", datapath) -%}
    {%- endif -%}
    {%- if '${{ uid:"' in b -%}
      {%- set b = replace_uid_tokens(b) -%}
    {%- endif -%}
    {%- if '${{ gid:"' in b -%}
      {%- set b = replace_gid_tokens(b) -%}
    {%- endif -%}
    {%- if '${{ tz' in b -%}
      {%- set b = b | replace('${{ tz }}', timezone) -%}
    {%- endif -%}
    {{ b }}
  {%- endif -%}
{%- endmacro -%}


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

{% set file_body = render_body(file.body, file.name, datapath) %}
configure_compose_{{ file.name }}_file:
  file.managed:
    - name: '{{ composeFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_yml.j2
    - context:
        file: {{ file | json }}
        datapath: {{ datapath }}
        body: {{ file_body.strip() | json }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% set file_override = render_body(file.override, file.name, datapath) %}
configure_compose_{{ file.name }}_override:
  file.managed:
    - name: '{{ overrideFile }}'
    - source:
      - salt://{{ tpldir }}/files/override_yml.j2
    - context:
        file: {{ file | json }}
        datapath: {{ datapath }}
        body: {{ file_override.strip() | json }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{% set file_env = render_body(file.env, file.name, datapath) %}
configure_compose_env_{{ file.name }}_file:
  file.managed:
    - name: '{{ envFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_env_yml.j2
    - context:
        file: {{ file | json }}
        datapath: {{ datapath }}
        body: {{ file_env.strip() | json }}
    - template: jinja
    - user: "{{ config.composeowner }}"
    - group: "{{ config.composegroup }}"
    - mode: "{{ config.fileperms }}"

{%- for cnf in config.configs.config | selectattr("fileref", "equalto", file.uuid) %}

{% set cnfFile = composeDir ~ '/' ~ cnf.name %}
{% set cnf_body = resolve_sf(cnf.body) %}

configure_compose_{{ file.name }}_config_{{ cnf.uuid }}:
  file.managed:
    - name: '{{ cnfFile }}'
    - source:
      - salt://{{ tpldir }}/files/compose_cnf.j2
    - context:
        file: {{ cnf | json }}
        body: {{ cnf_body | json }}
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
