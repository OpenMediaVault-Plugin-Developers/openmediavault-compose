<?php
/**
 * Copyright (C) 2022-2023 OpenMediaVault Plugin Developers
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
        $this->registerMethod("getFile");
        $this->registerMethod("setFile");
        $this->registerMethod("deleteFile");
        $this->registerMethod("doCommand");
        $this->registerMethod("doPrune");

        $this->registerMethod("getDockerfileList");
        $this->registerMethod("getDockerfile");
        $this->registerMethod("setDockerfile");
        $this->registerMethod("deleteDockerfile");
        $this->registerMethod("doBuild");

        $this->registerMethod("getExampleList");
        $this->registerMethod("setExample");

        $this->registerMethod("getServicesList");
        $this->registerMethod("getServicesListBg");
        $this->registerMethod("doServiceCommand");

        $this->registerMethod("getContainerList");
        $this->registerMethod("getContainerListBg");
        $this->registerMethod("doContainerCommand");

        $this->registerMethod("enumerateContainers");
        $this->registerMethod("doAutocompose");

        $this->registerMethod("importExistingFolder");

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

        $this->registerMethod("getImages");
        $this->registerMethod("getImagesBg");
        $this->registerMethod("doDockerImageCmd");
    }

    public function getComposePath($context)
    {
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        // Get sharedfolder path
        $sfobject = $db->get("conf.service.compose");
        $sfref = $sfobject->get("sharedfolderref");
        $sfpath = "";
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
        } else {
            throw new \OMV\Exception("Please set shared folder for file storage.");
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
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.compose");
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
            // get ps output
            $cmdArgs = [];
            $cmdArgs[] = 'docker-compose';
            $cmdArgs[] = sprintf('--file "%s"', $composeFile);
            $cmdArgs[] = sprintf("--env-file '%s'", $envFile);
            $cmdArgs[] = 'ps';
            $cmdArgs[] = '--all';
            $cmdArgs[] = '--format "json"';
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->setQuiet(true);
            $output = [];
            $cmd->execute($output, $exitStatus);
            $containers = json_decode($output[0]);
            // get state of each container
            $down = 0;
            $exited = 0;
            $running = 0;
            if (count($containers) == 0) {
                $down++;
            } else {
                foreach ($containers as $cnt) {
                    if ($cnt->State == "running") {
                        $running++;
                    } elseif ($cnt->State == "exited") {
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
            throw new \OMV\Exception("Name is in use by a Dockerfile.");
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
        $cmdArgs[] = 'docker-compose';
        $cmdArgs[] = sprintf("--file '%s.yml'", $composeName);
        $cmdArgs[] = sprintf("--env-file '%s.env'", $composeName);
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
            throw new \OMV\Exception("Name is in use by a compose file.");
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
        $scriptFile = sprintf("%s/%s", $object->get('script'));
        $confFile = sprintf("%s/%s", $object->get('conf'));
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
                $path = sprintf("%s/%s/", $sfpath, $name);
                $cmdArgs = [];
                $cmdArgs[] = 'docker';
                $cmdArgs[] = 'build';
                if ($params['options'] == 'pull') {
                    $cmdArgs[] = '--pull';
                }
                $cmdArgs[] = '--progress plain';
                $cmdArgs[] = sprintf("--tag '%s'", $params['name']);
                $cmdArgs[] = $path;
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
                $cmdArgs = [];
                $cmdArgs[] = 'docker-compose';
                $cmdArgs[] = sprintf("--file '%s.yml'", $composeName);
                $cmdArgs[] = sprintf("--env-file '%s.env'", $composeName);
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
        $db = \OMV\Config\Database::getInstance();
        $sfobject = $db->get("conf.service.compose");
        if (!is_uuid($sfobject->get("sharedfolderref"))) {
            throw new \OMV\Exception("Please set shared folder for file storage.");
        }
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
            $exists = file_exists($filepath);
            if ($exists) {
                // Get images
                $cmdArgs = [];
                $cmdArgs[] = 'docker-compose';
                $cmdArgs[] = sprintf('--file "%s"', $filepath);
                if ($envfilepath != '') {
                        $cmdArgs[] = sprintf("--env-file '%s'", $envfilepath);
                }
                $cmdArgs[] = 'ps';
                $cmdArgs[] = '--all';
                $cmdArgs[] = '--format "json"';
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setQuiet(true);
                $output = [];
                $cmd->execute($output, $exitStatus);
                $images = json_decode($output[0]);
                foreach ($images as $image) {
                    $ports = [];
                    foreach ($image->Publishers as $publisher) {
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
                        "name" => $image->Name,
                        "image" => $image->Image,
                        "project" => $image->Project,
                        "service" => $image->Service,
                        "ports" => implode('<br/>', $ports),
                        "created" => date("Y-m-d H:i:s", $image->Created),
                        "state" => $image->State,
                        "status" => $image->Status,
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
        return $this->execBgProc(function($bgStatusFilename, $bgOutputFilename)
            use ($params) {
                $cmdArgs = [];
                $cmdArgs[] = 'docker-compose';
                $cmdArgs[] = sprintf("--file '%s'", $params['path']);
                $cmdArgs[] = sprintf("--env-file '%s'", $params['envpath']);
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
        $this->validateMethodParams($params, "rpc.compose.doautocomplete");
        // Verify that shared folder is set
        $db = \OMV\Config\Database::getInstance();
        $sfobject = $db->get("conf.service.compose");
        if (!is_uuid($sfobject->get("sharedfolderref"))) {
            throw new \OMV\Exception("Please set shared folder for file storage.");
        }
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
        $db->assertIsUnique($object, 'name');
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function importExistingFolder($params, $context)
    {
        // Verify that shared folder is set
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
                $cmdArgs[] = 'inspect';
                $cmdArgs[] = $params['name'];
                $cmdArgs[] = '| jq .';
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

    public function getNetworksBg($params, $context) {
        return $this->callMethodBg("getNetworks", $params, $context);
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
                $cmdArgs[] = 'inspect';
                $cmdArgs[] = $params['name'];
                $cmdArgs[] = '| jq .';
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
        } else {
            $cmdArgs[] = sprintf("--subnet=%s", $params['subnet']);
            $cmdArgs[] = sprintf("--gateway=%s", $params['gateway']);
            $cmdArgs[] = sprintf("--ip-range=%s", $params['iprange']);
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
        $objects = [];
        // Get images
        $cmdArgs = [];
        $cmdArgs[] = 'docker';
        $cmdArgs[] = 'image';
        $cmdArgs[] = 'ls';
        $cmdArgs[] = '--all';
        $cmdArgs[] = '--format "json"';
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        $imagesAssoc = [];
        foreach ($output as $image) {
            $imageJson = json_decode($image);
            $imagesAssoc[] = [
                "id" => $imageJson->ID,
                "repo" => $imageJson->Repository,
                "createat" => $imageJson->CreatedAt,
                "createsince" => $imageJson->CreatedSince,
                "size" => $this->convertToBytes($imageJson->Size),
                "tag" => $imageJson->Tag,
                "virtualsize" => $this->convertToBytes($imageJson->VirtualSize)
            ];
        }
        // Filter the result.
        return $this->applyFilter($imagesAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir'], $params['search']);
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
                $cmdArgs[] = 'inspect';
                $cmdArgs[] = $params['id'];
                $cmdArgs[] = '| jq .';
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
