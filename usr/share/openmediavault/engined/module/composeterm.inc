<?php

class OMVModuleComposeTerm extends \OMV\Engine\Module\ServiceAbstract
    implements \OMV\Engine\Module\IServiceStatus
{
    public function getName()
    {
        return "compose_term";
    }

    public function getStatus()
    {
        $systemCtl = new \OMV\System\SystemCtl("omv_compose_term");
        return [
            "name" => $this->getName(),
            "title" => gettext("CTerm"),
            "enabled" => $systemCtl->isEnabled(),
            "running" => $systemCtl->isActive()
        ];
    }
}
