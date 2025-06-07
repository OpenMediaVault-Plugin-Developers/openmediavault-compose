#!/bin/bash

grp="dockerterm"

if getent group "${grp}" > /dev/null; then
    groupdel --force "${grp}"
fi

exit 0
