#!/bin/bash
# -------------------------------------
# Tezos systemd service protocol update
# -------------------------------------
# @Author: Richard Ayotte
# @Date:   2018-11-26 08:10:54
#
# Running this script, with the approriate permissions, will update your tezos
# systemd scripts from the old to the new protocol version. Make sure the
# OLD_VERSION and NEW_VERSION variables are set to the correct values. If you're
# not running it as root, you probably need to use sudo.

SYSTEMD_PATH=/etc/systemd/system
OLD_VERSION=002-PsYLVpVv
NEW_VERSION=003-PsddFKi3
APPS=("baker" "endorser" "accuser")

for app in "${APPS[@]}"
do
    sed -i "s/tezos-$app-$OLD_VERSION/tezos-$app-$NEW_VERSION/g" $SYSTEMD_PATH/tezos-$app.service
    systemctl enable "tezos-$app.service"
done

# You'll need to reload-restart the services for the change to take affect.
# Uncomment both of the following lines if you'd like to do that immediately.
# systemctl daemon-reload
# systemctl reload-or-restart 'tezos*.service'
