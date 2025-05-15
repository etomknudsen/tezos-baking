#!/bin/sh
#set -eux

echo "Starting the tezos-node-cpr.sh v0.4 (etomknudsen, May 2025 - full monitoring + email alerts)"

# --- Configuration ---

# RPC settings
RPC_HOST=127.0.0.1
RPC_PORT=8732

# Baker's Public Key Hash (change this)
BAKER_PKH="tz1YourBakerAddressHere"

# Networking interface
NETWORK_INTERFACE="enp1s0"

# Email alerts
ENABLE_EMAIL_ALERTS=true
ALERT_ON_MISSED_BAKES=true
ALERT_ON_MISSED_ATTESTATIONS=true
ALERT_EMAIL="you@example.com"
EMAIL_SUBJECT_PREFIX="[Tezos CPR Alert]"

# Restart thresholds
MAX_MISSED_ATTESTATIONS=5
MAX_MISSED_BAKES=3

# Timeout settings
TIME_TO_WAIT_AFTER_REBOOT=5
TIME_TO_WAIT_FOR_NETWORK=10
TIME_TO_WAIT_AFTER_RESTART=60
TIME_TO_WAIT_FOR_RPC_SERVER=30
TIME_TO_RETRY_P2P=10
TIME_TO_WAIT_FOR_P2P=90
TIME_TO_WAIT_FOR_BLOCK=180
TIME_TO_WAIT_FOR_BLOCK_MAX=600

# --- Initialization ---
LAST_REBOOT=$(date -d "$(who -b | cut -c22-38)" +"%s")
[ "$(date +%s)" -lt $((LAST_REBOOT + TIME_TO_WAIT_AFTER_REBOOT)) ] && sleep "$TIME_TO_WAIT_AFTER_REBOOT"

# --- Helper Functions ---

log() {
    echo "$(date -u +"%Y-%m-%dT%TZ") $1"
}

safe_jq() {
    local json="$1"
    local query="$2"
    echo "$json" | jq -r "$query" 2>/dev/null || echo ""
}

sendEmailAlert() {
    local subject="$1"
    local message="$2"
    if [ "$ENABLE_EMAIL_ALERTS" = "true" ]; then
        echo "$message" | mail -s "$EMAIL_SUBJECT_PREFIX $subject" "$ALERT_EMAIL"
    fi
}

# --- RPC Checks ---

getLastBlockHeaderInfo() {
    local key="$1"
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/header")
    [ -n "$response" ] && safe_jq "$response" ".${key} // empty" || echo ""
}

getTimeSinceLastBlock() {
    local ts=$(getLastBlockHeaderInfo timestamp)
    [ -n "$ts" ] && echo $(( $(date +%s) - $(date -d "$ts" +%s) )) || echo 999999
}

getTotalTxp2p() {
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/network/stat")
    [ -n "$response" ] && safe_jq "$response" '(.total_recv // 0) + (.total_sent // 0)' || echo 0
}

getAttestationCountFromLastBlock() {
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/operations")
    [ -n "$response" ] && echo "$response" | jq -r '.[0] | length' || echo 0
}

didMyBakerAttestLastBlock() {
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/operations")
    echo "$response" | jq -r --arg BAKER "$BAKER_PKH" \
    '.[0][] | select(.contents[].kind == "attestation") | .contents[] | select(.attester == $BAKER) | .attester' | grep -q "$BAKER_PKH" && echo "yes" || echo "no"
}

getBlockProducer() {
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/metadata")
    [ -n "$response" ] && safe_jq "$response" '.baker' || echo ""
}

getMyBakingRightsForLevel() {
    local level="$1"
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/helpers/baking_rights?level=$level&delegates=$BAKER_PKH&max_priority=5")
    [ -n "$response" ] && echo "$response" | jq -r '.[] | select(.delegate == "'"$BAKER_PKH"'") | .priority' | xargs || echo ""
}

# --- Network Checks ---

networkconnected() {
    [ "$(cat /sys/class/net/$NETWORK_INTERFACE/operstate 2>/dev/null)" = "up" ] && echo true
}

pingconnected() {
    ping -q -c 1 -W 1 8.8.8.8 >/dev/null && echo true || echo false
}

internetconnected() {
    curl -sf http://google.com > /dev/null && echo true || echo false
}

rpcserverrunning() {
    curl -sf "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/header" >/dev/null && echo true
}

# --- Monitoring State ---

MISSED_ATTESTATION_COUNT=0
MISSED_BAKING_COUNT=0

# --- Main Loop ---

if [ "$(rpcserverrunning)" != "true" ]; then
    sleep "$TIME_TO_WAIT_FOR_RPC_SERVER"
fi

if [ "$(rpcserverrunning)" = "true" ]; then
    while true; do
        P2P_TX_TOTAL=$(getTotalTxp2p)

        if [ "$(networkconnected)" = "true" ] && \
           [ "$(rpcserverrunning)" = "true" ] && \
           [ "$(getTimeSinceLastBlock)" -le "$TIME_TO_WAIT_FOR_BLOCK" ]; then

            BLOCK_HASH=$(getLastBlockHeaderInfo hash)
            BLOCK_TIME=$(getLastBlockHeaderInfo timestamp)
            TIME_SINCE_BLOCK=$(getTimeSinceLastBlock)
            ATTESTATION_COUNT=$(getAttestationCountFromLastBlock)
            MY_BAKER_ATTESTED=$(didMyBakerAttestLastBlock)
            BLOCK_PRODUCER=$(getBlockProducer)
            CURRENT_LEVEL=$(getLastBlockHeaderInfo level)
            MY_BAKING_RIGHTS=$(getMyBakingRightsForLevel "$CURRENT_LEVEL")

            BAKED_BY_ME="no"
            [ "$BLOCK_PRODUCER" = "$BAKER_PKH" ] && BAKED_BY_ME="yes"

            log "$BLOCK_HASH @ $BLOCK_TIME (${TIME_SINCE_BLOCK}s ago) | att: $ATTESTATION_COUNT | my att: $MY_BAKER_ATTESTED | my bake: $BAKED_BY_ME"

            # --- Attestation Handling ---
            if [ "$MY_BAKER_ATTESTED" = "yes" ]; then
                MISSED_ATTESTATION_COUNT=0
            else
                MISSED_ATTESTATION_COUNT=$((MISSED_ATTESTATION_COUNT + 1))
                log "⚠️ Missed attestation from $BAKER_PKH (missed count: $MISSED_ATTESTATION_COUNT)"
                if [ "$ALERT_ON_MISSED_ATTESTATIONS" = "true" ]; then
                    sendEmailAlert "Missed Attestation" "Your baker ($BAKER_PKH) did not attest at level $CURRENT_LEVEL. Missed count: $MISSED_ATTESTATION_COUNT"
                fi
                if [ "$MISSED_ATTESTATION_COUNT" -ge "$MAX_MISSED_ATTESTATIONS" ]; then
                    log "🚨 Missed $MISSED_ATTESTATION_COUNT attestations. Restarting node."
                    sendEmailAlert "Restarting Node (Attestation Failure)" "Baker missed $MISSED_ATTESTATION_COUNT attestations in a row. Node restart triggered."
                    systemctl reload-or-restart tezos-node
                    sleep "$TIME_TO_WAIT_AFTER_RESTART"
                    MISSED_ATTESTATION_COUNT=0
                    continue
                fi
            fi

            # --- Baking Handling ---
            if [ "$MY_BAKING_RIGHTS" != "" ]; then
                if [ "$BAKED_BY_ME" = "yes" ]; then
                    MISSED_BAKING_COUNT=0
                else
                    MISSED_BAKING_COUNT=$((MISSED_BAKING_COUNT + 1))
                    log "⚠️ Missed baking slot at level $CURRENT_LEVEL (missed count: $MISSED_BAKING_COUNT)"
                    if [ "$ALERT_ON_MISSED_BAKES" = "true" ]; then
                        sendEmailAlert "Missed Baking Slot" "Your baker ($BAKER_PKH) missed a baking slot at level $CURRENT_LEVEL. Missed count: $MISSED_BAKING_COUNT"
                    fi
                    if [ "$MISSED_BAKING_COUNT" -ge "$MAX_MISSED_BAKES" ]; then
                        log "🚨 Missed $MISSED_BAKING_COUNT baking slots. Restarting node."
                        sendEmailAlert "Restarting Node (Baking Failure)" "Baker missed $MISSED_BAKING_COUNT baking slots in a row. Node restart triggered."
                        systemctl reload-or-restart tezos-node
                        sleep "$TIME_TO_WAIT_AFTER_RESTART"
                        MISSED_BAKING_COUNT=0
                        continue
                    fi
                fi
            fi

            sleep "$TIME_TO_WAIT_FOR_P2P"

        else
            if [ "$(networkconnected)" = "true" ] && [ "$(rpcserverrunning)" = "true" ]; then
                log "Looking for p2p
