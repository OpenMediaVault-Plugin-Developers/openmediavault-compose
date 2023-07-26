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
