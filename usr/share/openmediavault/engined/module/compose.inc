<?php

/**
 * Copyright (C) 2022-2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVModuleCompose extends \OMV\Engine\Module\ServiceAbstract
    implements \OMV\Engine\Notify\IListener, \OMV\Engine\Module\IServiceStatus
{
    public function getName()
    {
        return "compose";
    }

    public function getStatus()
    {
        $db = \OMV\Config\Database::getInstance();
        $settings = $db->get("conf.service.compose");
        $podman = $settings->get('podman');

        $svc = 'docker';
        $svcname = 'Docker';
        $svcpath = '/lib/systemd/system/docker.service';
        if ($podman) {
            $svc = 'podman.socket';
            $svcname = 'Podman';
            $svcpath = '/lib/systemd/system/podman.socket';
        }

        if (file_exists($svcpath)) {
            $systemCtl = new \OMV\System\SystemCtl($svc);
            $enabled = $systemCtl->isEnabled();
            $running = $systemCtl->isActive();
        } else {
            $enabled = false;
            $running = false;
        }
        return array(
            "name" => $svcname,
            "title" => $svcname,
            "enabled" => $enabled,
            "running" => $running
        );
    }

    final public function onSharedFolder($type, $path, $object)
    {
        $db = \OMV\Config\Database::getInstance();
        if (TRUE === $db->exists("conf.service.compose.file", [
            "operator" => "stringEquals",
            "arg0" => "sharedfolderref",
            "arg1" => $object['uuid']
        ])) {
            $this->setDirty();
        }
    }

    public function bindListeners(\OMV\Engine\Notify\Dispatcher $dispatcher)
    {
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            "org.openmediavault.conf.service.compose",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.compose.file",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            "org.openmediavault.conf.service.compose.globalenv",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.compose.dockerfile",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.compose.job",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            "org.openmediavault.conf.system.sharedfolder",
            [ $this, "onSharedFolder" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_MODIFY,
            "org.openmediavault.conf.system.sharedfolder.privilege",
            [ $this, "onSharedFolder" ]
        );
    }
}
