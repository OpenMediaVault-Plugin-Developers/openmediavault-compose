<?php
/**
 * Copyright (C) 2022-2024 OpenMediaVault Plugin Developers
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
    private $url = "https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/compose-files";

    public function getName()
    {
        return "Compose";
    }

    public function initialize()
    {
        $this->registerMethod("get");
        $this->registerMethod("set");
        $this->registerMethod("reinstallDocker");
        $this->registerMethod("restartDocker");

        $this->registerMethod("getFileList");
        $this->registerMethod("getFileListBg");
        $this->registerMethod("getFileListSuggest");
        $this->registerMethod("getFile");
        $this->registerMethod("setFile");
        $this->registerMethod("deleteFile");
        $this->registerMethod("doCommand");
        $this->registerMethod("doPrune");

        $this->registerMethod("getGlobalEnv");
        $this->registerMethod("setGlobalEnv");

        $this->registerMethod("getDockerfileList");
        $this->registerMethod("getDockerfile");
        $this->registerMethod("setDockerfile");
        $this->registerMethod("deleteDockerfile");
        $this->registerMethod("doBuild");
        $this->registerMethod("doTag");
        $this->registerMethod("doHubPush");

        $this->registerMethod("getExampleList");
        $this->registerMethod("setExample");

        $this->registerMethod("setUrl");

        $this->registerMethod("getServicesList");
        $this->registerMethod("getServicesListBg");
        $this->registerMethod("doServiceCommand");
        $this->registerMethod("getServiceLog");

        $this->registerMethod("getContainerList");
        $this->registerMethod("getContainerListBg");
        $this->registerMethod("doContainerCommand");
        $this->registerMethod("getContainerLog");

        $this->registerMethod("enumerateContainers");
        $this->registerMethod("doAutocompose");

        $this->registerMethod("importChanges");
        $this->registerMethod("importExistingFolder");
        $this->registerMethod("importExistingOne");

        $this->registerMethod("getStats");
        $this->registerMethod("getStatsBg");
        $this->registerMethod("doDockerCmd");

        $this->registerMethod("getContainers");

        $this->registerMethod("getVolumes");
        $this->registerMethod("getVolumesBg");
        $this->registerMethod("doDockerVolumeCmd");

        $this->registerMethod("getNetworks");
        $this->registerMethod("getNetworksBg");
        $this->registerMethod("doDockerNetworkCmd");
        $this->registerMethod("setNetwork");
        $this->registerMethod("enumerateNetworkList");

        $this->registerMethod("getImages");
        $this->registerMethod("getImagesBg");
        $this->registerMethod("doDockerImageCmd");

        $this->registerMethod('getRestoreList');
        $this->registerMethod('doRestore');

        $this->registerMethod('getJobList');
        $this->registerMethod('getJob');
        $this->registerMethod('setJob');
        $this->registerMethod('deleteJob');
        $this->registerMethod('doJob');
    }

    private function getComposePath($context)
    {
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        // Get sharedfolder path
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("sharedfolderref");
        $sfpath = "";
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
            $sfpath = rtrim($sfpath, '/');
        } else {
            throw new \OMV\Exception(gettext("Please set shared folder for file storage."));
        }
        return ($sfpath);
    }

    private function getDockerPath($context)
    {
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        // Get sharedfolder path
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("datasharedfolderref");
        $sfpath = "";
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
            $sfpath = rtrim($sfpath, '/');
        } else {
            $sfpath = "";
        }
        return ($sfpath);
    }

    private function getBackupPath($context)
    {
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        // Get sharedfolder path
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("backupsharedfolderref");
        $sfpath = "";
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
            $sfpath = rtrim($sfpath, '/');
        } else {
            throw new \OMV\Exception(gettext("Please set shared folder for backups."));
        }
        return ($sfpath);
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
        $object->remove("dockerfiles");
        // docker version
        $cmdLine = 'dpkg -l | awk \'$1 == "ii" && ($2 == "docker-ce" || $2 == "docker.io") { print $2 " " $3 }\'';
        $cmd = new \OMV\System\Process($cmdLine);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        // compose version
        $cmdLine = 'dpkg -l | awk \'$1 == "ii" && ($2 == "docker-compose-plugin" || $2 == "docker-compose") { print $2 " " $3 }\'';
        $cmd = new \OMV\System\Process($cmdLine);
        $cmd->setQuiet(true);
        $output2 = [];
        $cmd->execute($output2, $exitStatus);
        if (!empty($output)) {
            // Get docker service status
            $systemCtl = new \OMV\System\SystemCtl('docker');
            if ($systemCtl->isActive()) {
                $running = gettext("and running");
            } else {
                $running = gettext("and not running");
            }
            $status = sprintf('%s %s', gettext("Installed"), $running);
            $dockerVersion = $output[0];
            $composeVersion = $output2[0];
        } else {
            $status = gettext("Not installed");
            $dockerVersion = gettext("n/a");
            $composeVersion = gettext("n/a");
        }
        $object->add('dockerStatus', 'string', $status);
        $object->add('dockerVersion', 'string', $dockerVersion);
        $object->add('composeVersion', 'string', $composeVersion);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.set");
        // Make sure compose file shared folder is not the same as data shared folder
        if ($params['sharedfolderref'] != '' && $params['sharedfolderref'] == $params['datasharedfolderref']) {
            throw new \OMV\ExecException(
                gettext("Compose file shared folder must be different than data shared folder")
            );
        }
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose");
        $perms = "";
        switch ($params['mode']) {
            case "700": $perms = "600"; break;
            case "750": $perms = "640"; break;
            case "770": $perms = "660"; break;
            case "755": $perms = "644"; break;
            case "775": $perms = "664"; break;
            case "777": $perms = "666"; break;
            default:    $perms = "600";
        }
        $params['fileperms'] = $perms;
        $object->setAssoc($params);
        $db->set($object);
        // Remove useless properties from the object.
        $object->remove("files");
        $object->remove("dockerfiles");
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function reinstallDocker($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'apt-get';
                $cmdArgs[] = '--yes';
                $cmdArgs[] = '--autoremove';
                $cmdArgs[] = 'purge';
                $cmdArgs[] = 'docker-ce';
                $cmdArgs[] = 'docker.io';
                $cmdArgs[] = 'containerd.io';
                $cmdArgs[] = 'containerd';
                $cmdArgs[] = 'docker-ce-cli';
                $cmdArgs[] = 'docker-compose-plugin';
                $cmdArgs[] = 'docker-compose';
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $cmdArgs = [];
                $cmdArgs[] = 'omv-salt';
                $cmdArgs[] = 'deploy';
                $cmdArgs[] = 'run';
                $cmdArgs[] = 'compose';
                $cmd = new \OMV\System\Process($cmdArgs);
                //$cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                }
                return $output;
            }
        );
    }

    public function restartDocker($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $systemCtl = new \OMV\System\SystemCtl('docker');
        $systemCtl->restart();
    }

    public function getFileList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.compose.file");
        $sfpath = $this->getComposePath($context);
        // Add additional informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            // build filenames
            $cname = $objectv->get('name');
            $composeDir = sprintf("%s/%s", $sfpath, $cname);
            $composeName = sprintf("%s/%s", $composeDir, $cname);
            $composeFile = sprintf("%s.yml", $composeName);
            $envFile = sprintf("%s.env", $composeName);
            $globalEnvFile = sprintf("%s/global.env", $sfpath);
            // get ps output
            $cmdArgs = [];
            $cmdArgs[] = 'docker';
            $cmdArgs[] = 'compose';
            $cmdArgs[] = sprintf('--file "%s"', $composeFile);
            $cmdArgs[] = sprintf("--env-file '%s'", $envFile);
            if (file_exists($globalEnvFile)) {
                $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
            }
            $cmdArgs[] = 'ps';
            $cmdArgs[] = '--all';
            $cmdArgs[] = '--format "json"';
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->setQuiet(true);
            $output = [];
            $cmd->execute($output, $exitStatus);
            array_filter($output);
            // get state of each container
            $down = 0;
            $exited = 0;
            $running = 0;
            if (count($output) == 0) {
                $down++;
            } else {
                foreach ($output as $cnt) {
                    $cntj = json_decode($cnt);
                    if ($cntj->State == "running") {
                        $running++;
                    } elseif ($cntj->State == "exited") {
                        $exited++;
                    } else {
                        $down++;
                    }
                }
            }
            $status = [];
            if ($running > 0) $status[] = "UP";
            if ($exited > 0) $status[] = "STOPPED";
            if ($down > 0) $status[] = "DOWN";
            $objectv->add('status', 'string', implode(',', $status));
            $filedate = filemtime($composeFile);
            if ($filedate === false) $filedate = 0;
            $objectv->add('filedate', 'integer', $filedate);
            $objectv->add('status', 'string', implode(',', $status));
            $objectv->add('build', 'boolean', false);
            if (stripos($objectv->get('body'), 'build:') !== false) {
                $objectv->set('build', true);
            }
            $objectv->remove('body');
            $objectv->remove('env');
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getFileListBg($params, $context) {
        return $this->callMethodBg("getFileList", $params, $context);
    }

    public function getFileListSuggest($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.compose.file");
        // Add additional informations.
        $files = [];
        $files[] = '*';
        foreach ($objects as $objectk => &$objectv) {
            $files[] = $objectv->get('name');
        }
        // Filter the result.
        return ($files);
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
        $sfpath = $this->getComposePath($context);
        // If data path string is used in file body, verify that data shared folder is set
        if (strpos($params['body'], 'CHANGE_TO_COMPOSE_DATA_PATH') !== false) {
            $datapath = $this->getDockerPath($context);
            if ($datapath == '') {
                throw new \OMV\Exception(
                  gettext("Please set shared folder for data on the Settings tab.")
                );
            }
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
        $dockerfiles = $db->getByFilter("conf.service.compose.dockerfile", [
            "operator" => "stringEquals",
            "arg0" => "name",
            "arg1" => $params['name']
        ]);
        if ($dockerfiles) {
            throw new \OMV\Exception(gettext("Name is in use by a Dockerfile."));
        }
        // update database
        $db->set($object);
        // Apply changes immmediately
        \OMV\Rpc\Rpc::call('Config', 'applyChanges', [
            'modules' => [ 'compose' ],
            'force' => TRUE
        ], $context);
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
        $sfpath = $this->getComposePath($context);
        // Delete the configuration object.
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        $cname = $object->get('name');
        $composeDir = sprintf("%s/%s", $sfpath, $cname);
        $composeName = sprintf("%s/%s", $composeDir, $cname);
        $composeFile = sprintf("%s.yml", $composeName);
        $envFile = sprintf("%s.env", $composeName);
        // stop container(s) if running
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'compose';
        $cmdArgs[] = sprintf("--file '%s.yml'", $composeName);
        $cmdArgs[] = sprintf("--env-file '%s.env'", $composeName);
        if (file_exists($globalEnvFile)) {
            $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
        }
        $cmdArgs[] = 'down';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        // remove files
        if (file_exists($composeFile)) {
            unlink($composeFile);
        }
        if (file_exists($envFile)) {
            unlink($envFile);
        }
        if (file_exists($composeDir)) {
            rmdir($composeDir);
        }
        // delete database entry
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function getGlobalEnv($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.globalenv");
        return $object->getAssoc();
    }

    public function setGlobalEnv($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.setglobalenv");
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.globalenv");
        $object->setAssoc($params);
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function getDockerfileList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.compose.dockerfile");
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getDockerfile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.compose.dockerfile", $params['uuid']);
    }

    public function setDockerfile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.setdockerfile");
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getComposePath($context);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.dockerfile");
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            // Check uniqueness - name
            $db->assertIsUnique($object, "name");
        }
        $files = $db->getByFilter("conf.service.compose.file", [
            "operator" => "stringEquals",
            "arg0" => "name",
            "arg1" => $params['name']
        ]);
        if ($files) {
            throw new \OMV\Exception(gettext("Name is in use by a compose file."));
        }
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteDockerfile($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getComposePath($context);
        // Delete the configuration object.
        $object = $db->get("conf.service.compose.dockerfile", $params['uuid']);
        $dname = $object->get('name');
        $dockerDir = sprintf("%s/%s", $sfpath, $dname);
        $dockerFile = sprintf("%s/Dockerfile", $dockerDir);
        $scriptFile = sprintf("%s/%s", $dockerDir, $object->get('script'));
        $confFile = sprintf("%s/%s", $dockerDir, $object->get('conf'));
        if (file_exists($dockerFile)) {
            unlink($composeFile);
        }
        if (file_exists($scriptFile)) {
            unlink($envFile);
        }
        if (file_exists($confFile)) {
            unlink($envFile);
        }
        if (file_exists($composeDir)) {
            rmdir($composeDir);
        }
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function doBuild($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        $sfpath = $this->getComposePath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($object, $params, $sfpath) {
                $name = $params['name'];
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'build';
                if ($params['options'] == 'pull') {
                    $cmdArgs[] = '--pull';
                }
                $cmdArgs[] = '--progress plain';
                $cmdArgs[] = sprintf("--tag '%s'", $params['name']);
                $cmdArgs[] = sprintf("'%s/%s/'", $sfpath, $name);
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

    public function doTag($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $sfpath = $this->getComposePath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params, $sfpath) {
                // docker tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'tag';
                if (strlen($params['srcid']) > 0) {
                    $cmdArgs[] = $params['srcid'];
                } elseif (strlen($params['srctag']) > 0) {
                    $cmdArgs[] = sprintf('%s:%s', $params['srcimg'], $params['srctag']);
                } else {
                    $cmdArgs[] = $params['srcimg'];
                }
                if (strlen($params['tgttag']) > 0) {
                    $cmdArgs[] = sprintf('%s:%s', $params['tgtimg'], $params['tgttag']);
                } else {
                    $cmdArgs[] = $params['tgtimg'];
                }
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

    public function doHubPush($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $sfpath = $this->getComposePath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params, $sfpath) {
                // docker tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'image';
                $cmdArgs[] = 'push';
                if (strlen($params['imgtag']) > 0) {
                    $cmdArgs[] = sprintf('%s:%s', $params['imgname'], $params['imgtag']);
                } else {
                    $cmdArgs[] = $params['imgimg'];
                }
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

    public function doCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        $sfpath = $this->getComposePath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($object, $params, $sfpath) {
                $cname = $object->get('name');
                $composeName = sprintf("%s/%s/%s", $sfpath, $cname, $cname);
                $globalEnvFile = sprintf("%s/global.env", $sfpath);
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'compose';
                $cmdArgs[] = sprintf("--file '%s.yml'", $composeName);
                $cmdArgs[] = sprintf("--env-file '%s.env'", $composeName);
                if (file_exists($globalEnvFile)) {
                    $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
                }
                $cmdArgs[] = $params['command'];
                $quiet = \OMV\Environment::getBoolean("OMV_COMPOSE_QUIET", false);
                if ($quiet) {
                    switch ($params['command']) {
                        case 'pull': $cmdArgs[] = '--quiet'; break;
                        case 'up -d': $cmdArgs[] = '--quiet-pull'; break;
                    }
                }
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

    public function doPrune($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.doprune");
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = '-f';
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

    public function getExampleList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Download example list
        $listUrl = sprintf("%s/list.json", $this->url);
        $list = file_get_contents($listUrl);
        $listJson = json_decode($list, true);
        // create list
        $objects = [];
        foreach ($listJson as $image) {
            $objects[] = [
                "name" => $image['name'],
                "description" => sprintf("%s - %s", $image['name'], $image['description'])
            ];
        }
        // Filter the result.
        return ($objects);
    }

    public function setExample($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.setexample");
        // Verify that shared folder is set
        $this->getComposePath($context);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
        $name = $params['example'];
        $url = sprintf("%s/%s/%s", $this->url, $name, $name);
        $body = file_get_contents(sprintf("%s.yml", $url));
        $env = file_get_contents(sprintf("%s.env", $url));
        // set object values
        $object->set('name', $params['name']);
        $object->set('description', $params['description']);
        $object->set('body', $body);
        $object->set('env', $env);
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $db->assertIsUnique($object, "name");
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function setUrl($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.seturl");
        // Verify that shared folder is set
        $this->getComposePath($context);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
        $body = trim(file_get_contents($params['url']));
        // set object values
        $object->set('name', $params['name']);
        $object->set('description', $params['description']);
        $object->set('body', $body);
        $object->set('env', '');
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $db->assertIsUnique($object, "name");
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function getServicesList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getComposePath($context);
        $settings = $db->get("conf.service.compose");
        // get fqdn
        $dns = $db->get('conf.system.network.dns');
        $fqdn = $dns->get('hostname');
        $dn = $dns->get('domainname');
        if (strlen($dn) > 1) {
            $fqdn = sprintf('%s.%s', $fqdn, $dn);
        }
        // populate containers
        $imagesAssoc = [];
        $objects = $db->get("conf.service.compose.file");
        foreach ($objects as $objectk => &$objectv) {
            $cname = $objectv->get('name');
            $path = sprintf("%s/%s/%s", $sfpath, $cname, $cname);
            $filepath = sprintf("%s.yml", $path);
            $envfilepath = sprintf("%s.env", $path);
            $globalEnvFile = sprintf("%s/global.env", $sfpath);
            $exists = file_exists($filepath);
            if ($exists) {
                // Get images
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'compose';
                $cmdArgs[] = sprintf('--file "%s"', $filepath);
                if ($envfilepath != '') {
                        $cmdArgs[] = sprintf("--env-file '%s'", $envfilepath);
                }
                if (file_exists($globalEnvFile)) {
                    $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
                }
                $cmdArgs[] = 'ps';
                $cmdArgs[] = '--all';
                $cmdArgs[] = '--format "json"';
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setQuiet(true);
                $output = [];
                $cmd->execute($output, $exitStatus);
                array_filter($output);
                foreach ($output as $image) {
                    $imagej = json_decode($image);
                    $ports = [];
                    foreach ($imagej->Publishers as $publisher) {
                        $port = '';
                        $url = $publisher->URL;
                        $tgtPort = $publisher->TargetPort;
                        $pubPort = $publisher->PublishedPort;
                        $protocol = $publisher->Protocol;
                        if ($tgtPort > 0 && $pubPort > 0) {
                            $port .= sprintf('%d->', $pubPort);
                        }
                        $port .= sprintf('%s/%s', $tgtPort, $protocol);
                        if (strlen($url) > 0) $port .= sprintf(' [%s]', $url);
                        if ($protocol == "tcp") {
                            $hrefPort = 0;
                            if ($pubPort > 0) {
                                $hrefPort = $pubPort;
                            } else {
                                $hrefPort = $tgtPort;
                            }
                            $port = sprintf('<a href="http://%s:%d" target="_blank">%s</a>', $fqdn, $hrefPort, $port);
                        }
                        $ports[] = $port;
                    }
                    $imagesAssoc[] = [
                        "name" => $imagej->Name,
                        "image" => $imagej->Image,
                        "project" => $imagej->Project,
                        "service" => $imagej->Service,
                        "ports" => implode('<br/>', $ports),
                        "created" => date("Y-m-d H:i:s", $imagej->Created),
                        "state" => $imagej->State,
                        "status" => $imagej->Status,
                        "filepath" => $filepath,
                        "envpath" => $envfilepath
                    ];
                }
            }
        }
        // Filter the result.
        return $this->applyFilter($imagesAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getServicesListBg($params, $context) {
        return $this->callMethodBg("getServicesList", $params, $context);
    }

    public function doServiceCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $sfpath = $this->getComposePath($context);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params, $sfpath) {
                $globalEnvFile = sprintf("%s/global.env", $sfpath);
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'compose';
                $cmdArgs[] = sprintf("--file '%s'", $params['path']);
                $cmdArgs[] = sprintf("--env-file '%s'", $params['envpath']);
                if (file_exists($globalEnvFile)) {
                    $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
                }
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = $params['command2'];
                $quiet = \OMV\Environment::getBoolean("OMV_COMPOSE_QUIET", false);
                if ($quiet) {
                    switch ($params['command']) {
                        case 'pull': $cmdArgs[] = '--quiet'; break;
                        case 'up -d': $cmdArgs[] = '--quiet-pull'; break;
                    }
                }
                $cmdArgs[] = $params['service'];
                array_filter($cmdArgs);
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

    function getServiceLog($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.getservicelog");
        // Create a temporary file which will contain the content of the requested log file.
        $tmpFilePath = tempnam(sys_get_temp_dir(), 'dockerlogfile');
        // Execute the given command to get the log file content.
        $sfpath = $this->getComposePath($context);
        $globalEnvFile = sprintf('%s/global.env', $sfpath);
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'compose';
        $cmdArgs[] = sprintf("--file '%s'", $params['path']);
        $cmdArgs[] = sprintf("--env-file '%s'", $params['envpath']);
        if (file_exists($globalEnvFile)) {
            $cmdArgs[] = sprintf("--env-file '%s'", $globalEnvFile);
        }
        $cmdArgs[] = 'logs';
        $cmdArgs[] = $params['service'];
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setRedirect1toFile($tmpFilePath);
        $cmd->setRedirect2to1();
        $cmd->execute();
        // Modify the file mode/owner to allow the WebGUI PHP backend to unlink it.
        chmod($tmpFilePath, 0700);
        chown($tmpFilePath, \OMV\Environment::get('OMV_WEBGUI_FILE_OWNERGROUP_NAME'));
        // Return values required by generic download RPC implementation.
        return [
            'filename' => sprintf('%s_%s.log', $params['service'],$params['name']),
            'filepath' => $tmpFilePath,
            'unlink' => TRUE
        ];
    }


    public function getContainerList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $settings = $db->get("conf.service.compose");
        // get fqdn
        $dns = $db->get('conf.system.network.dns');
        $fqdn = $dns->get('hostname');
        $dn = $dns->get('domainname');
        if (strlen($dn) > 1) {
            $fqdn = sprintf('%s.%s', $fqdn, $dn);
        }
        // populate containers
        $cntAssoc = [];
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'container';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--all';
        $cmdArgs[] = '--no-trunc';
        $cmdArgs[] = '--format "json"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        foreach ($output as $line) {
            $container = json_decode($line);
            $portList = explode(',', $container->Ports);
            $mounts = explode(',', $container->Mounts);
            $ports = [];
            foreach ($portList as $port) {
                $match = [];
                if (preg_match('/:(.*?)->/', str_replace(':::', ':', $port), $match) == 1) {
                    $ports[] = sprintf('<a href="http://%s:%s" target="_blank">%s</a>', $fqdn, $match[1], $port);
                } else {
                    $ports[] = $port;
                }
            }
            $cntAssoc[] = [
                "id" => $container->ID,
                "name" => $container->Names,
                "image" => $container->Image,
                "ports" => implode('<br/>', $ports),
                "mounts" => implode('<br/>', $mounts),
                "created" => $container->CreatedAt,
                "state" => $container->State,
                "status" => $container->Status,
                "running" => $container->RunningFor,
                "command" => $container->Command,
                "network" => $container->Networks
            ];
        }
        // Filter the result.
        return $this->applyFilter($cntAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getContainerListBg($params, $context) {
        return $this->callMethodBg("getContainerList", $params, $context);
    }

    public function doContainerCommand($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = $params['command2'];
                $cmdArgs[] = $params['id'];
                array_filter($cmdArgs);
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

    function getContainerLog($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.getcontainerlog");
        // Create a temporary file which will contain the content of the requested log file.
        $tmpFilePath = tempnam(sys_get_temp_dir(), 'dockerlogfile');
        // Execute the given command to get the log file content.
        $sfpath = $this->getComposePath($context);
        $globalEnvFile = sprintf('%s/global.env', $sfpath);
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'logs';
        $cmdArgs[] = $params['id'];
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setRedirect1toFile($tmpFilePath);
        $cmd->setRedirect2to1();
        $cmd->execute();
        // Modify the file mode/owner to allow the WebGUI PHP backend to unlink it.
        chmod($tmpFilePath, 0700);
        chown($tmpFilePath, \OMV\Environment::get('OMV_WEBGUI_FILE_OWNERGROUP_NAME'));
        // Return values required by generic download RPC implementation.
        return [
            'filename' => sprintf('%s_%s.log', $params['name'],$params['id']),
            'filepath' => $tmpFilePath,
            'unlink' => TRUE
        ];
    }

    public function enumerateContainers($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get running containers
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'container';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--format "{{.Names}},{{.Image}}"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $objects = [];
        foreach ($output as $line) {
            $cntr = explode(',', $line);
            $objects[] = [
                'desc' => sprintf('%s (%s)', trim($cntr[0]), trim($cntr[1])),
                'name' => trim($cntr[0])
            ];
        }
        return ($objects);
    }

    public function doAutocompose($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.doautocompose");
        // Verify that shared folder is set
        $this->getComposePath($context);
        // Get running containers
        $cmdArgs = [];
        $cmdArgs[] = 'python3';
        $cmdArgs[] = '/usr/bin/autocompose.py';
        $cmdArgs[] = sprintf('-v %s', $params['version']);
        $cmdArgs[] = $params['container'];
        $cmd = new \OMV\System\Process($cmdArgs);
        $output = [];
        $cmd->execute($output, $exitStatus);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
        // set object values
        $object->set('name', $params['name']);
        $object->set('description', $params['description']);
        $object->set('body', trim(implode(PHP_EOL, $output)));
        $object->set('env', '');
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $db->assertIsUnique($object, 'name');
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function importChanges($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Verify that shared folder is set
        $sfpath = $this->getComposePath($context);
        $dockerpath = $this->getDockerPath($context);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.file", $params['uuid']);
        // Set paths
        $cname = $object->get('name');
        $composeDir = sprintf("%s/%s", $sfpath, $cname);
        $composeName = sprintf("%s/%s", $composeDir, $cname);
        $composeFile = sprintf("%s.yml", $composeName);
        $envFile = sprintf("%s.env", $composeName);
        // Get file content
        $composeContent = trim(file_get_contents($composeFile));
        $envContent = trim(file_get_contents($envFile));
        if ($dockerpath != '') {
            $composeContent = preg_replace('/'.str_replace('/','\/',$dockerpath).'/', 'CHANGE_TO_COMPOSE_DATA_PATH', $composeContent);
        }
        // Update object
        $object->set('body', $composeContent);
        $object->set('env', $envContent);
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function importExistingFolder($params, $context)
    {
        // Verify that shared folder is set
        $sfpath = $this->getComposePath($context);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $path = $params['path'];
        $path = (substr($path, 0, 1) == '/' ? $path : '/' . $path);
        $dirs = array_diff(scandir($path), ["..", "."]);
        foreach ($dirs as $dir) {
            $full = sprintf('%s/%s', $path, $dir);
            if (!is_dir($full)) {
                continue;
            }
            $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
            // get compose file
            $bodyFile = sprintf('%s/%s.yml', $full, $dir);
            if (!file_exists($bodyFile)) {
                $bodyFile = sprintf('%s/docker-compose.yml', $full);
                if (!file_exists($bodyFile)) {
                    continue;
                }
            }
            $body = file_get_contents($bodyFile);
            // get environment file if it exists
            $envFile = sprintf('%s/%s.env', $full, $dir);
            if (file_exists($envFile)) {
                $env = file_get_contents($envFile);
                if ($env == false || is_null($env)) $env = '';
            } else {
                $env = '';
            }
            // set object values
            $object->set('name', $dir);
            $object->set('description', 'imported ' . date("Y.m.d H:i"));
            $object->set('body', $body);
            $object->set('env', $env);
            // Set the configuration object.
            try {
                $db->assertIsUnique($object, 'name');
            } catch (Exception $e) {
                continue;
            }
            $db->set($object);
        }
    }

    public function importExistingOne($params, $context)
    {
        // Verify that shared folder is set
        $sfpath = $this->getComposePath($context);
        // Get the configuration object.
        $path = $params['path'];
        $path = (substr($path, 0, 1) == '/' ? $path : '/' . $path);
        if (!is_dir($path)) {
            throw new \OMV\ExecException($path . ' does not exist!');
        }
        $name = basename(rtrim($path, '/'));
        // get body
        $bodyFile = sprintf('%s/%s.yml', $path, $name);
        if (!file_exists($bodyFile)) {
            $bodyFile = sprintf('%s/docker-compose.yml', $path);
            if (!file_exists($bodyFile)) {
                throw new \OMV\ExecException(gettext("No compose file found!"));
            }
        }
        $body = file_get_contents($bodyFile);
        // get env (if exists)
        $envFile = sprintf('%s/%s.env', $path, $name);
        if (!file_exists($envFile)) {
            $envFile = sprintf('%s/.env', $path);
        }
        $env = '';
        if (file_exists($envFile)) {
            $env = file_get_contents($envFile);
            if ($env === false || $env === null) {
                $env = '';
            }
        }
        // set object values
        $object = new \OMV\Config\ConfigObject("conf.service.compose.file");
        $object->set('name', $name);
        $object->set('description', 'imported ' . date("Y.m.d H:i"));
        $object->set('body', $body);
        $object->set('env', $env);
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        try {
            $db->assertIsUnique($object, 'name');
        } catch (Exception $e) {
            throw new \OMV\ExecException("A compose file with the name '$name' already exists!");
        }
        $db->set($object);
    }

    public function getStats($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get running containers
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'stats';
        $cmdArgs[] = '--no-stream';
        $cmdArgs[] = '--format "{{.ID}},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $objects = [];
        foreach ($output as $line) {
            $cntr = explode(',', $line);
            $cpu = floatval(trim(str_replace('%', '', $cntr[2])));
            $memUL = explode('/', $cntr[3]);
            $memUse = $this->convertToBytes($memUL[0]);
            $memLim = $this->convertToBytes($memUL[1]);
            $mem = floatval(trim(str_replace('%', '', $cntr[4])));
            $net = explode('/', $cntr[5]);
            $netIn = $this->convertToBytes($net[0]);
            $netOut = $this->convertToBytes($net[1]);
            $block = explode('/', $cntr[6]);
            $blockIn = $this->convertToBytes($block[0]);
            $blockOut = $this->convertToBytes($block[1]);
            $objects[] = [
                'id' => trim($cntr[0]),
                'name' => trim($cntr[1]),
                'cpu' => $cpu,
                'memuse' => $memUse,
                'memlim' => $memLim,
                'mem' => $mem,
                'netin' => $netIn,
                'netout' => $netOut,
                'blockin' => $blockIn,
                'blockout' => $blockOut,
                'pids' => intval(trim($cntr[7]))
            ];
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getStatsBg($params, $context) {
        return $this->callMethodBg("getStats", $params, $context);
    }

    private function convertToBytes($val)
    {
        $valL = strtolower($val);
        $level = 1;
        if (strpos($val, 'k')) {
            $level = 1024;
        } elseif (strpos($valL, 'm')) {
            $level = pow(1024, 2);
        } elseif (strpos($valL, 'g')) {
            $level = pow(1024, 3);
        } elseif (strpos($valL, 't')) {
            $level = pow(1024, 4);
        } elseif (strpos($valL, 'p')) {
            $level = pow(1024, 5);
        }
        return (intval(floatval($val) * $level));
    }

    public function doDockerCmd($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.dodockercmd");
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = $params['cmd'];
                $cmdArgs[] = $params['cmd2'];
                $cmdArgs[] = $params['id'];
                array_filter($cmdArgs);
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

    public function getContainers($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $objects = [];
        $status = '';
        // check to see if docker is installed and running
        if (file_exists("/lib/systemd/system/docker.service")) {
            $systemCtl = new \OMV\System\SystemCtl("docker");
            $running = $systemCtl->isActive();
            $status = $running ? gettext('running') : gettext('stopped');
        } else {
            $running = false;
            $status = gettext('not installed');
        }
        // get containers and status if docker is running
        $objects[] = [
            'image' => '',
            'name' => 'Docker',
            'status' => $status
        ];
        if ($running) {
            $output = [];
            $cmdArgs = [];
            $cmdArgs[] = 'docker';
            $cmdArgs[] = 'container';
            $cmdArgs[] = 'ls';
            $cmdArgs[] = '--all';
            $cmdArgs[] = '--format "{{.Image}},{{.Names}},{{.Status}}"';
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->execute($output, $exitStatus);
            foreach ($output as $cnt) {
                if (empty($cnt)) {
                    continue;
                }
                $parts = explode(',', $cnt);
                $objects[] = [
                    'image' => $parts[0],
                    'name' => $parts[1],
                    'status' => $parts[2]
                ];
            }
        }
        return ($objects);
    }

    public function getVolumes($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $objects = [];
        // Get images
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'volume';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--format "json"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $volumesAssoc = [];
        foreach ($output as $volume) {
            $volumeJson = json_decode($volume);
            $volumesAssoc[] = [
                "name" => $volumeJson->Name,
                "mountpoint" => $volumeJson->Mountpoint,
                "driver" => $volumeJson->Driver
            ];
        }
        // Filter the result.
        return $this->applyFilter($volumesAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getVolumesBg($params, $context) {
        return $this->callMethodBg("getVolumes", $params, $context);
    }

    public function doDockerVolumeCmd($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'volume';
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = $params['name'];
                if ($params['command'] == 'inspect') {
                    $cmdArgs[] = '| jq .';
                }
                array_filter($cmdArgs);
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

    public function getNetworks($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $objects = [];
        // Get networks
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'network';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--format "json"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $networksAssoc = [];
        foreach ($output as $network) {
            $networkJson = json_decode($network);
            $networksAssoc[] = [
                "name" => $networkJson->Name,
                "driver" => $networkJson->Driver
            ];
        }
        // Filter the result.
        return $this->applyFilter($networksAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    public function getNetworksBg($params, $context)
    {
        return $this->callMethodBg("getNetworks", $params, $context);
    }

    function enumerateNetworkList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Get the system network interface devices.
        $objects = \OMV\Rpc\Rpc::call('Network', 'enumerateDevices', NULL, $context);
        $devices = [];
        foreach ($objects as $device) {
            $devices[] = $device['devicename'];
        }
        sort($devices);
        $devicesf = array_diff($devices, ['lo']);
        // Filter the result.
        return $this->applyFilter($devicesf, $params['start'],
            $params['limit'], $params['sortfield'], $params['sortdir']);
    }

    public function doDockerNetworkCmd($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'network';
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = $params['name'];
                if ($params['command'] == 'inspect') {
                    $cmdArgs[] = '| jq .';
                }
                array_filter($cmdArgs);
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

    public function setNetwork($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $driver = $params['driver'];
        // Get networks
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'network';
        $cmdArgs[] = 'create';
        $cmdArgs[] = sprintf("--driver %s", $driver);
        if ($driver == 'macvlan') {
            $cmdArgs[] = sprintf("--opt parent=%s", $params['parentnetwork']);
        }
        if ($params['subnet']) {
            $cmdArgs[] = sprintf("--subnet=%s", $params['subnet']);
        }
        if ($params['gateway']) {
            $cmdArgs[] = sprintf("--gateway=%s", $params['gateway']);
        }
        if ($params['iprange']) {
            $cmdArgs[] = sprintf("--ip-range=%s", $params['iprange']);
        }
        if ($params['auxaddress']) {
            $aux = explode(',', $params['auxaddress']);
            foreach ($aux as $entry) {
                $cmdArgs[] = sprintf('--aux-address="%s"', trim($entry));
            }
        }
        $cmdArgs[] = $params['name'];
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setRedirect2to1();
        $cmd->execute($output, $exitStatus);
        return $output;
    }

    public function getImages($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $skipStatus = \OMV\Environment::getBoolean('OMV_COMPOSE_SKIP_IMAGE_STATUS', false);
        $objects = [];
        // Get container images
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'container';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--all';
        $cmdArgs[] = '--format "{{ .Image }}"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $containerImages = [];
        $cmd->execute($containerImages, $exitStatus);
        array_filter($containerImages);
        // Get images
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'image';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--all';
        $cmdArgs[] = '--digests';
        $cmdArgs[] = '--format "json"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $imagesAssoc = [];
        foreach ($output as $image) {
            $imageJson = json_decode($image);
            $inuse = false;
            foreach ($containerImages as $img) {
                $imginfo = explode(':', $img);
                if ($imginfo[0] == $imageJson->Repository) {
                    if (strlen($imginfo[1]) > 0) {
                        if ($imginfo[1] == $imageJson->Tag) {
                            $inuse = true;
                            break;
                        }
                    } else {
                        $inuse = true;
                        break;
                    }
                }
            }
            if ($skipStatus) {
                $status = 'NA';
            } else {
                $status = $this->getImageStatus($imageJson->Repository, $imageJson->Tag, $imageJson->Digest, $context);
            }
            $imagesAssoc[] = [
                "id" => $imageJson->ID,
                "repo" => $imageJson->Repository,
                "createat" => $imageJson->CreatedAt,
                "createsince" => $imageJson->CreatedSince,
                "size" => $this->convertToBytes($imageJson->Size),
                "tag" => $imageJson->Tag,
                "digest" => $imageJson->Digest,
                "status" => $status,
                "virtualsize" => $this->convertToBytes($imageJson->VirtualSize),
                "inuse" => $inuse
            ];
        }
        // Filter the result.
        return $this->applyFilter($imagesAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
    }

    private function getImageStatus($img, $tag, $digest, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // return n/a if no digest or image name
        if ($img == "<none>" || $tag == "<none>" || $digest == "<none>" ||
          strlen($img) == 0 || strlen($tag) == 0 || strlen($digest) == 0) {
            return 'NA';
        }
        // Unable to get digests from other registries
        $registry = "/^(lscr.io|ghcr.io|quay.io|mcr.microsoft.com)/";
        if (preg_match($registry, $img) == 1) {
            return 'NA';
        }
        // prepend library for single name images
        if (strpos($img, '/') === false) {
            $img = 'library/' . $img;
        }
        $url = '';
        $lscr = false;
        // get latest digest from docker hub
        if (strpos($img, 'lscr.io') !== false) {
            $apiUrl = 'https://lscr.io/v2';
            $url = sprintf('%s/%s/manifests/%s', $apiUrl, $img, $tag);
            $lscr = true;
        } else {
            $apiUrl = 'https://hub.docker.com/v2/repositories';
            $url = sprintf('%s/%s/tags/%s', $apiUrl, $img, $tag);
        }
        $response = @file_get_contents($url);
        $newest = '';
        if ($response === false) {
            return 'FAILED';
        } else {
            $data = json_decode($response, true);
            if ($lscr) {
                if (isset($data['config']['digest'])) {
                    $newest = $data['config']['digest'];
                }
            } else {
                if (isset($data['digest'])) {
                    $newest = $data['digest'];
                } elseif (isset($data['images'])) {
                    $newest = $data['images'][0]['digest'];
                }
            }
        }
        if ($newest == '') {
            return 'FAILED';
        } elseif ($digest != $newest) {
            return 'AVAILABLE';
        } else {
            return 'CURRENT';
        }
    }

    public function getImagesBg($params, $context) {
        return $this->callMethodBg("getImages", $params, $context);
    }

    public function doDockerImageCmd($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'image';
                $cmdArgs[] = $params['command'];
                $cmdArgs[] = $params['id'];
                if ($params['command'] == 'inspect') {
                    $cmdArgs[] = '| jq .';
                }
                array_filter($cmdArgs);
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

    public function getRestoreList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // get backup list from list file
        $sfpath = $this->getBackupPath($context);
        $dirs = array_diff(scandir($sfpath), ["..", "."]);
        $objects = [];
        foreach($dirs as $dir) {
            $volList = sprintf("%s/%s/vol.list", $sfpath, $dir);
            if (file_exists($volList)) {
                $spaceUsed = sprintf("%s/%s/space.used", $sfpath, $dir);
                $backupSize = -1;
                if (file_exists($spaceUsed)) {
                    $backupSize = intval(file_get_contents($spaceUsed));
                }
                $objects[] = [
                    'backup' => $dir,
                    'backupsize' => $backupSize,
                    'time' => date("Y-m-d H:i:s", filemtime($volList))
                ];
            }
        }
        return ($objects);
    }

    public function doRestore($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = '/usr/sbin/omv-compose-restore';
                $cmdArgs[] = $params['backup'];
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

    public function getJobList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.compose.job");
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    function getJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.job", $params['uuid']);
        return $object->getAssoc();
    }

    function setJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.compose.setjob");
        if (!$params['backup'] && !$params['update'] && !$params['prune']) {
            throw new \OMV\ExecException(gettext('You must select at least one action type!'));
        }
        if ($params['backup']) {
            $params['prebackup'] = trim($params['prebackup']);
            $params['postbackup'] = trim($params['postbackup']);
            if (strlen($params['prebackup']) > 1 && !file_exists($params['prebackup'])) {
                throw new \OMV\ExecException(gettext('The prebackup script does not exist!'));
            }
            if (strlen($params['postbackup']) > 1 && !file_exists($params['postbackup'])) {
                throw new \OMV\ExecException(gettext('The postbackup script does not exist!'));
            }
        } else {
            $params['prebackup'] = '';
            $params['postbackup'] = '';
        }
        $params['filter'] = str_replace(['@','(',')',' '], '', $params['filter']);
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.compose.job");
        $db = \OMV\Config\Database::getInstance();
        $object->setAssoc($params);
        // Set the configuration object.
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deleteJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Delete the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.job", $params['uuid']);
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function doJob($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose.job", $params['uuid']);
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($object) {
                $output = [];
                if ($object->get('backup')) {
                    $cmdArgs = [];
                    $cmdArgs[] = '/usr/sbin/omv-compose-backup-multi';
                    $cmdArgs[] = sprintf("'%s'", $object->get('filter'));
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                }
                if ($object->get('update')) {
                    $cmdArgs = [];
                    $cmdArgs[] = '/usr/sbin/omv-compose-update-multi';
                    $cmdArgs[] = sprintf("'%s'", $object->get('filter'));
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                }
                if ($object->get('prune')) {
                    $cmdArgs = [];
                    $cmdArgs[] = '/usr/bin/docker';
                    $cmdArgs[] = 'image';
                    $cmdArgs[] = 'prune';
                    $cmdArgs[] = '-f';
                    $cmd = new \OMV\System\Process($cmdArgs);
                    $cmd->setRedirect2to1();
                    $cmdLine = $cmd->getCommandLine();
                    if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                        throw new \OMV\ExecException($cmdLine, $output);
                    }
                }
                return $output;
            }
        );
    }
}
