#!/bin/bash

grp="dockerterm"

if getent group "${grp}" > /dev/null; then
    groupdel "${grp}"
fi

exit 0
