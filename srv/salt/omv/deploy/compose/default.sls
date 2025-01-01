# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2025 openmediavault plugin developers
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

{% set dirpath = '/srv/salt' | path_join(tpldir) %}

include:
{% for file in salt['file.readdir'](dirpath) %}
{% if file not in ('.', '..', 'init.sls', 'default.sls') %}
{% if file.endswith('.sls') %}
  - .{{ file | replace('.sls', '') }}
{% endif %}
{% endif %}
{% endfor %}
