#!/bin/bash

echo [`date`] Bootstrapping the Web server...

function clean_up {
    # Perform program exit housekeeping
    echo [`date`] Stopping the service...
    service apache2 stop
    exit
}

# Fix UID & GID for user 'site'
echo [`date`] Fixing filesystem permissions...

ORIGPASSWD=$(cat /etc/passwd | grep site)
ORIG_UID=$(echo $ORIGPASSWD | cut -f3 -d:)
ORIG_GID=$(echo $ORIGPASSWD | cut -f4 -d:)
ORIG_HOME=$(echo "$ORIGPASSWD" | cut -f6 -d:)
DEV_UID=${DEV_UID:=$ORIG_UID}
DEV_GID=${DEV_GID:=$ORIG_GID}

if [ "$DEV_UID" -ne "$ORIG_UID" ] || [ "$DEV_GID" -ne "$ORIG_GID" ]; then

    # note: we allow non-unique user and group ids...
    groupmod -o -g "$DEV_GID" site
    usermod -o -u "$DEV_UID" -g "$DEV_GID" site

    chown "${DEV_UID}":"${DEV_GID}" "${ORIG_HOME}"
    chown -R "${DEV_UID}":"${DEV_GID}" "${ORIG_HOME}"/.*

fi

chown -R site:site /var/lock/apache2

echo [`date`] Modifying Apache configuration...

a2dissite 000-default

echo [`date`] Starting the service...

trap clean_up SIGTERM

service apache2 restart

echo [`date`] Bootstrap finished

tail -f /dev/null &
child=$!
wait "$child"
