#!/bin/sh
#set -eux

echo "Starting the tezos-node-cpr.sh v 0.5 (etomknudsen, updated May 2025)"

# Get timestamp for last reboot
LAST_REBOOT=$(date -d "$(who -b | cut -c22-38)" +"%s")

# Networking interface
NETWORK_INTERFACE="enx3c18a056d703"

# Set RPC parameters
RPC_HOST=127.0.0.1
RPC_PORT=8732

# Attestation monitoring config
BAKER_PKH="tz1eLbDXYceRsPZoPmaJXZgQ6pzgnTQvZtpo"
MAX_MISSED_ATTESTATIONS=5
BLOCK_OFFSET=3

# Block time configuration
BLOCK_TIME=10  # in seconds

# Set timeouts (seconds)
TIME_TO_WAIT_AFTER_REBOOT=5
TIME_TO_WAIT_FOR_NETWORK=10
TIME_TO_WAIT_AFTER_RESTART=60
TIME_TO_WAIT_FOR_RPC_SERVER=30
TIME_TO_RETRY_P2P=4
TIME_TO_WAIT_FOR_P2P=15
TIME_TO_WAIT_FOR_BLOCK=30
TIME_TO_WAIT_FOR_BLOCK_MAX=60
TIME_TO_WAIT_FOR_ATTESTATION=30

# State tracking
MISSED_ATTESTATIONS=0

# --- Function Definitions ---

safe_jq() {
    local json="$1"
    local query="$2"
    echo "$json" | jq -r "$query" 2>/dev/null || echo ""
}

getLastBlockHeaderInfo() {
    local key="$1"
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/header")
    if [ -n "$response" ]; then
        safe_jq "$response" ".${key} // empty"
    else
        echo ""
    fi
}

getTimeSinceLastBlock() {
    last_ts=$(getLastBlockHeaderInfo timestamp)
    if [ -n "$last_ts" ]; then
        echo $(( $(date +%s) - $(date -d "$last_ts" +%s) ))
    else
        echo 999999
    fi
}

getTotalTxp2p() {
    local response=$(curl -s "$RPC_HOST:$RPC_PORT/network/stat")
    if [ -n "$response" ]; then
        safe_jq "$response" '(.total_recv // 0) + (.total_sent // 0)'
    else
        echo 0
    fi
}

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

log() {
    echo "$(date -u +"%Y-%m-%dT%TZ") $1"
}

get_current_block_height() {
    curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/header" | jq -r '.level'
}

get_attestation_rights_count() {
    local level="$1"
    curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/head/helpers/attestation_rights?delegate=$BAKER_PKH&level=$level" |
        jq --arg BAKER "$BAKER_PKH" '[.[] | .delegates[] | select(.delegate == $BAKER) | .attestation_power] | add // 0'
}

get_attested_count() {
    local level="$1"
    RAW_OUTPUT=$(curl -s "$RPC_HOST:$RPC_PORT/chains/main/blocks/$level/operations")
    echo "$RAW_OUTPUT" | jq --arg BAKER "$BAKER_PKH" '
        flatten |
        map(select(.contents[]? | select(.kind == "attestation" and .metadata.delegate == $BAKER))) |
        length
    '
}

check_attestation_status() {
    local current_level=$(get_current_block_height)
    local target_level=$((current_level - BLOCK_OFFSET))
    local rights=$(get_attestation_rights_count "$target_level")
    local actual=$(get_attested_count "$target_level")

    if ! [ "$rights" -eq "$rights" ] 2>/dev/null || ! [ "$actual" -eq "$actual" ] 2>/dev/null; then
        log "Could not parse attestation data for level $target_level"
        return 1
    fi

    if [ "$rights" -gt 0 ] && [ "$actual" -eq 0 ]; then
        log "No attestations injected at level $target_level"
        return 1
    else
        log "Attestation check at level $target_level: slots = $rights, injected = $actual"
        return 0
    fi
}

# --- Main Control Flow ---
LAST_BLOCK_HASH=""
MAX_MISSING_ATTESTATIONS=5   # Define the number of missing attestations before restarting the node
MISSING_ATTESTATIONS_COUNT=0 # Counter for missing attestations

if [ "$(rpcserverrunning)" != "true" ]; then
    sleep "$TIME_TO_WAIT_FOR_RPC_SERVER"
fi

if [ "$(rpcserverrunning)" = "true" ]; then
    while true; do
        CURRENT_BLOCK_HASH=$(getLastBlockHeaderInfo hash)
        CURRENT_BLOCK_LEVEL=$(getLastBlockHeaderInfo level)
        TIME_SINCE_LAST_BLOCK=$(getTimeSinceLastBlock)

        if [ "$CURRENT_BLOCK_HASH" != "$LAST_BLOCK_HASH" ]; then
            log "Processing new block: Level: $CURRENT_BLOCK_LEVEL, $TIME_SINCE_LAST_BLOCK secs old"

            P2P_TX_TOTAL=$(getTotalTxp2p)

            if ! [ "$P2P_TX_TOTAL" -eq "$P2P_TX_TOTAL" ] 2>/dev/null; then
                P2P_TX_TOTAL=0
            fi

            if ! [ "$TIME_SINCE_LAST_BLOCK" -eq "$TIME_SINCE_LAST_BLOCK" ] 2>/dev/null; then
                TIME_SINCE_LAST_BLOCK=0
            fi

            # Check if the node is behind (not within the acceptable block time)
            if [ "$TIME_SINCE_LAST_BLOCK" -le "$TIME_TO_WAIT_FOR_BLOCK" ]; then
                :
                #log "$(getLastBlockHeaderInfo hash) @ $(getLastBlockHeaderInfo timestamp) ($(getTimeSinceLastBlock) secs ago)"
            else
                log "Node is falling behind. Last block processed: $CURRENT_BLOCK_HASH"
                # Restart the node if it's falling behind
                systemctl reload-or-restart octez-node
                sleep "$TIME_TO_WAIT_AFTER_RESTART"
            fi

            # Check for attestations (or lack thereof)
            BLOCK_LEVEL=$(get_current_block_height)
            TARGET_LEVEL=$((BLOCK_LEVEL - BLOCK_OFFSET))
            RIGHTS=$(get_attestation_rights_count "$TARGET_LEVEL")
            ATTESTED=$(get_attested_count "$TARGET_LEVEL")

            if ! [ "$RIGHTS" -eq "$RIGHTS" ] 2>/dev/null || ! [ "$ATTESTED" -eq "$ATTESTED" ] 2>/dev/null; then
                log "Failed to retrieve valid attestation data for level $TARGET_LEVEL ($BLOCK_OFFSET blocks ago)"
            else
                log "Attestation slots: $RIGHTS | Attestations injected: $(if [ "$ATTESTED" -gt 0 ]; then echo "Yes"; else echo "No"; fi)"

                if [ "$RIGHTS" -eq 0 ]; then
                    log "No attestation slots for level $TARGET_LEVEL — nothing to attest."
                elif [ "$ATTESTED" -eq 0 ]; then
                    log "No round 0 attestations injected at level $TARGET_LEVEL!"
                    # Increment the missing attestations count
                    MISSING_ATTESTATIONS_COUNT=$((MISSING_ATTESTATIONS_COUNT + 1))

                    # If we've missed too many attestations, restart the node
                    if [ "$MISSING_ATTESTATIONS_COUNT" -ge "$MAX_MISSING_ATTESTATIONS" ]; then
                        log "Too many missing attestations. Restarting the node!"
                        systemctl reload-or-restart octez-node
                        sleep "$TIME_TO_WAIT_AFTER_RESTART"
                        MISSING_ATTESTATIONS_COUNT=0  # Reset the counter after restart
                    fi
                else
                    log "Attestations injected at level $TARGET_LEVEL ($BLOCK_OFFSET blocks ago): Yes"
                    # Reset the missing attestations count if attestations were found
                    MISSING_ATTESTATIONS_COUNT=0
                fi
            fi

            # Update LAST_BLOCK_HASH to the current block's hash after processing
            LAST_BLOCK_HASH="$CURRENT_BLOCK_HASH"
        fi

        # Sleep for half a block time
        sleep "$((BLOCK_TIME / 2))"
    done
else
    log "RPC server not available. Exiting."
    exit 1
fi

