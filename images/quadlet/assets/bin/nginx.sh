#!/bin/bash
# shellcheck disable=all

# Mostly a copy of
# https://github.com/pulp/pulp-oci-images/blob/296646383e2656ede57928a2b6b3914a6d8a1230/images/compose/assets/bin/nginx.sh
# Modified to handle the case where only the first nameserver from /etc/resolv.conf
# works correctly under Podman (the nameserver list can be unreliable).

set -e

if [ "$container" == "podman" ]; then
    export NAMESERVER=$(cat /etc/resolv.conf | grep "nameserver" | awk '{print $2}' | head -n1)
else
    export NAMESERVER=$(cat /etc/resolv.conf | grep "nameserver" | awk '{print $2}' | tr '\n' ' ')
fi

echo "Nameserver is: $NAMESERVER"

echo "Generating nginx config"
envsubst '$NAMESERVER' </etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

for file in /etc/nginx/pulp/*.conf; do
    echo "Modifying $file"
    sed -i 's/pulp-api/$pulp_api:24817/' $file
    sed -i 's/pulp-content/$pulp_content:24816/' $file
done

echo "Starting nginx"
exec nginx -g "daemon off;"
