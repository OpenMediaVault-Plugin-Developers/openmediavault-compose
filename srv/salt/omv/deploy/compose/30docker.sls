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

{% set arch = grains['osarch'] %}
{% set omvextras = salt['omv_conf.get']('conf.system.omvextras') %}
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

docker_compose_install_packages:
  pkg.installed:
    - pkgs:
      - "{{ compose_pkg }}"
{% if docker | to_bool and not arch == 'i386' %}
      - containerd.io
      - docker-ce-cli
{% endif %}

{% if docker | to_bool and not arch == 'i386' %}
docker_purged_packages:
  pkg.purged:
    - pkgs:
      - docker-compose
{% endif %}
