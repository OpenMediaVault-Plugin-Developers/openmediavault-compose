<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @copyright Copyright (c) 2013-2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
 require_once("openmediavault/functions.inc");

\OMV\System\LogFileSpec::registerSpecification("omv-compose-backup", [
    "filename" => "omv-compose-backup.log",
    "filepath" => "/var/log/omv-compose-backup.log",
    "regex" => "/^\[((.*?)\s+(.*?))\]\s+\[(.*?)\]\s+(.*?)$/",
    "columns" => [
        "date" => 1,
        "action" => 4,
        "message" => 5
    ]
]);

\OMV\System\LogFileSpec::registerSpecification("omv-compose-restore", [
    "filename" => "omv-compose-restore.log",
    "filepath" => "/var/log/omv-compose-restore.log",
    "regex" => "/^\[((.*?)\s+(.*?))\]\s+\[(.*?)\]\s+(.*?)$/",
    "columns" => [
        "date" => 1,
        "action" => 4,
        "message" => 5
    ]
]);

\OMV\System\LogFileSpec::registerSpecification("omv-compose-update", [
    "filename" => "omv-compose-update.log",
    "filepath" => "/var/log/omv-compose-update.log",
    "regex" => "/^\[((.*?)\s+(.*?))\]\s+\[(.*?)\]\s+(.*?)$/",
    "columns" => [
        "date" => 1,
        "action" => 4,
        "message" => 5
    ]
]);

\OMV\System\LogFileSpec::registerSpecification("omv-compose-start", [
    "filename" => "omv-compose-start.log",
    "filepath" => "/var/log/omv-compose-start.log",
    "regex" => "/^\[((.*?)\s+(.*?))\]\s+\[(.*?)\]\s+(.*?)$/",
    "columns" => [
        "date" => 1,
        "action" => 4,
        "message" => 5
    ]
]);

\OMV\System\LogFileSpec::registerSpecification("omv-compose-stop", [
    "filename" => "omv-compose-stop.log",
    "filepath" => "/var/log/omv-compose-stop.log",
    "regex" => "/^\[((.*?)\s+(.*?))\]\s+\[(.*?)\]\s+(.*?)$/",
    "columns" => [
        "date" => 1,
        "action" => 4,
        "message" => 5
    ]
]);
