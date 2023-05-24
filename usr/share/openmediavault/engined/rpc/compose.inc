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

        $this->registerMethod("getContainerList");
        $this->registerMethod("doContainerCommand");

        $this->registerMethod("enumerateContainers");
        $this->registerMethod("doAutocompose");

        $this->registerMethod("importExistingFolder");

        $this->registerMethod("getStats");
        $this->registerMethod("doDockerCmd");

        $this->registerMethod("getContainers");
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
        // docker status
        $cmdLine = 'dpkg -l | awk \'$1 == "ii" && ($2 == "docker-ce" || $2 == "docker.io") { print $3 }\'';
        $cmd = new \OMV\System\Process($cmdLine);
        $cmd->setQuiet(true);
        $output = [];
        $cmd->execute($output, $exitStatus);
        if (!empty($output)) {
            // Get docker service status
            $systemCtl = new \OMV\System\SystemCtl('docker');
            if ($systemCtl->isActive()) {
                $running = gettext("and running");
            } else {
                $running = gettext("and not running");
            }
            $status = sprintf('%s %s', gettext("Installed"), $running);
            $version = $output[0];
        } else {
            $status = gettext("Not installed");
            $version = gettext("n/a");
        }
        $object->add('dockerStatus', 'string', $status);
        $object->add('dockerVersion', 'string', $version);
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
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
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
            $params['sortfield'], $params['sortdir']);
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

    public function getContainerList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $sfpath = $this->getComposePath($context);
        $objects = $db->get("conf.service.compose.file");
        // Add additional file information
        $imagesAssoc = [];
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
                $cmdArgs[] = sprintf("--env-file '%s'", $envfilepath);
                $cmdArgs[] = 'ps';
                $cmdArgs[] = '--all';
                $cmdArgs[] = '--format "json"';
                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setQuiet(true);
                $output = [];
                $cmd->execute($output, $exitStatus);
                $images = json_decode($output[0]);
                foreach ($images as $image) {
                    $imagesAssoc[] = [
                        "name" => $image->Name,
                        "image" => $image->Image,
                        "project" => $image->Project,
                        "service" => $image->Service,
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
            $params['sortfield'], $params['sortdir']);
    }

    public function doContainerCommand($params, $context)
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
                $cmdArgs[] = $params['service'];
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
            $bodyFile = sprintf('%s/%s.yml', $full, $dir);
            if (!file_exists($bodyFile)) {
                continue;
            }
            $body = file_get_contents(sprintf("%s/%s.yml", $full, $dir));
            $envFile = sprintf('%s/%s.env', $full, $dir);
            if (file_exists($bodyFile)) {
                $env = file_get_contents(sprintf("%s/%s.env", $full, $dir));
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
            $objects[] = [
                'id' => trim($cntr[0]),
                'name' => trim($cntr[1]),
                'cpu' => trim($cntr[2]),
                'memuse' => trim($cntr[3]),
                'mem' => trim($cntr[4]),
                'netio' => trim($cntr[5]),
                'blockio' => trim($cntr[6]),
                'pids' => trim($cntr[7])
            ];
        }
        return ($objects);
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
                $cmdArgs[] = $params['id'];
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
}
