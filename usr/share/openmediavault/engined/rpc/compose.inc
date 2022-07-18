<?php
/**
 * Copyright (C) 2022 OpenMediaVault Plugin Developers
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

class OMVRpcServiceCompose extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return "Compose";
    }

    public function initialize()
    {
        $this->registerMethod("get");
        $this->registerMethod("set");
        $this->registerMethod("getFileList");
        $this->registerMethod("getFile");
        $this->registerMethod("setFile");
        $this->registerMethod("deleteFile");
        $this->registerMethod("doCommand");
    }

    public function get($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose");
        // Remove useless properties from the object.
        $object->remove("files");
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.set");
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose");
        $object->setAssoc($params);
        $db->set($object);
        // Remove useless properties from the object.
        $object->remove("files");
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function getFileList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.compose.file");
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getFile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.compose.file", $params['uuid']);
    }

    public function setFile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.setfile");
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfobject = $db->get("conf.service.compose");
        if (!is_uuid($sfobject->get("sharedfolderref"))) {
            throw new \OMV\Exception("Please set shared folder for file storage.");
        }
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            // Check uniqueness - name
            $db->assertIsUnique($object, "name");
        }
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteFile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("sharedfolderref");
        if (!is_uuid($sfref)) {
            throw new \OMV\Exception("Please set shared folder for file storage.");
        }
        // Delete the configuration object.
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath",
          ["uuid" => $sfref], $context);
        $cname = $object->get('name');
        $composeDir = sprintf("%s/%s", $sfpath, $cname);
        $composeName = sprintf("%s/%s", $composeDir, $cname);
        $composeFile = sprintf("%s.yml", $composeName);
        $envFile = sprintf("%s.env", $composeName);
        if (file_exists($composeFile)) {
            unlink($composeFile);
        }
        if (file_exists($envFile)) {
            unlink($envFile);
        }
        if (file_exists($composeDir)) {
            rmdir($composeDir);
        }
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function doCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("sharedfolderref");
        if (!is_uuid($sfref)) {
            throw new \OMV\Exception("Please set shared folder for file storage.");
        }
        $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath",
          ["uuid" => $sfref], $context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($object, $params, $sfpath) {
                $cname = $object->get('name');
                $composeName = sprintf("%s/%s/%s", $sfpath, $cname, $cname);
                $cmdArgs = [];
                $cmdArgs[] = 'docker-compose';
                $cmdArgs[] = sprintf("--file '%s.yml'", $composeName);
                $cmdArgs[] = sprintf("--env-file '%s.env'", $composeName);
                $cmdArgs[] = $params['command'];
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }
}
