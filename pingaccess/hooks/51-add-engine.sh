#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This script is started in the background immediately before 
#- the server within the container is started
#-
#- This is useful to implement any logic that needs to occur after the
#- server is up and running
#-
#- For example, enabling replication in PingDirectory, initializing Sync 
#- Pipes in PingDataSync or issuing admin API calls to PingFederate or PingAccess

# shellcheck source=../../../../pingcommon/opt/staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

_out=/tmp/pa.api.request.out
pahost=${PA_CONSOLE_HOST}
_password=${PING_IDENTITY_PASSWORD:-PA_ADMIN_PASSWORD_INITIAL}

_pa_curl ()
{
     _curl \
        --insecure \
        --user "${ROOT_USER}:${_password}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output ${_out} \
        "${@}"
    return ${?}
}

if test -n "${OPERATIONAL_MODE}" && test "${OPERATIONAL_MODE}" = "CLUSTERED_ENGINE"
then
    echo "This node is an engine..."
    echo "Checking admin heartbeat: https://${pahost}:${PA_ADMIN_PORT}/pa/heartbeat.ping"
    while true
    do
        _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa/heartbeat.ping
        _pa_result=$?
        if test ${_pa_result} -ne 0 ; 
        then
            echo "Adding Engine: Server not started (curl=${pa_result}, waiting.."
            sleep 3
        else
            echo "PA started, begin adding engine"
            break
        fi
    done

    _pa_curl \
        https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/users/1 \
        2>/dev/null \
    || die_on_error 51 "Connection to admin unsuccessful, check vars PING_IDENTITY_PASSWORD and PA_CONSOLE_HOST"

    # Get Engine Certificate ID
    echo "Retrieving Key Pair ID from administration API..."
    _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/httpsListeners
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair ID"
    echo "############### 1 #################"
    cat "${_out}"
    jq "${_out}"
    echo ""
    echo "############### 1 #################"
    keypairid=$( jq '.items[] | select(.name=="CONFIG QUERY") | .keyPairId' "${_out}" )
    echo "KeyPairId:"${keypairid}

    echo "Retrieving the Key Pair alias..."
    _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/keyPairs
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair alias"
    echo "############### 2 #################"
    cat "${_out}"
    jq "${_out}"
    echo ""
    echo "############### 2 #################"
    kpalias=$( jq '.items[] | select(.id=='${keypairid}') | .alias' "${_out}" )
    echo "Key Pair Alias:"${kpalias}

    echo "Retrieving Engine Certificate ID..."
    _pa_curl  https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/engines/certificates
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve certificate ID"
    echo "############### 3 #################"
    cat "${_out}"
    jq "${_out}"
    echo ""
    echo "############### 3 #################"
    certid=$( jq '.items[] | select(.alias=='${kpalias}' and .keyPair==true) | .id' "${_out}" )
    echo "Engine Cert ID:"${certid}

    echo "Adding new engine"
    host=$( hostname )
    engineid=$( 
        curl \
            --insecure \
            --request POST \
            --user "${ROOT_USER}:${_password}" \
            --header "X-Xsrf-Header: PingAccess" \
            --data '{"name":"'"${host}"'", "selectedCertificateId": "'"${certid}"'"}' \
            https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/engines | jq '.id' )

    echo "EngineId: ${engineid}"
    echo "Retrieving the engine config..."
    curl \
        --insecure \
        --request POST \
        --user "${ROOT_USER}:${_password}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output /tmp/engine-config.zip \
        https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/engines/${engineid}/config

    echo "Extracting bootstrap and pa.jwk files to conf folder..."
    unzip -o /tmp/engine-config.zip -d "${OUT_DIR}/instance"
    # ls -la ${OUT_DIR}instance/conf
    # cat ${OUT_DIR}/instance/conf/bootstrap.properties
    chmod 400 "${OUT_DIR}/instance/conf/pa.jwk"

    echo "Cleanup zip.."
    rm /tmp/engine-config.zip
fi
