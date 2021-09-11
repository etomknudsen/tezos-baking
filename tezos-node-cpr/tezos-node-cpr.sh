#!/bin/bash
#set -eux

# Entire script assumes tezos-node runs as a service: 
echo "Starting the tezos-node-cpr.sh v 0.2 (etomknudsen, August 2021)"

# Get timestamp for last reboot
LAST_REBOOT=$(date -d "$(who -b | cut -c22-38)" +"%s")

# Networking interface
# Use "ls -la /sys/class/net/" to see which devices you have avaiable
ALLOW_WIFI=true
NETWORK_INTERFACE="wlp0s20f3" 
VPN_INTERFACE="tun0"

# Set conditions to force
FORCE_LAN=true
FORCE_VPN=true
FORCE_STRICT=true # Forcing caching of block data in same loop/cycle

# Set RPC parameters
RPC_HOST=127.0.0.1
RPC_PORT=8732
RPC_INT_URI="$RPC_HOST:$RPC_PORT"
RPC_EXT_URI="https://rpc-mainnet.ateza.io"
P2P_THRESHOLD=1024 # Amount of combined traffic to deem acceptable - B/s

# Set timeouts (seconds) - only integers allowed 
TIME_TO_WAIT_AFTER_REBOOT=15
TIME_TO_WAIT_AFTER_NODE_RESTART=20
TIME_TO_WAIT_FOR_LAN=5
TIME_TO_WAIT_FOR_VPN=3
TIME_TO_WAIT_FOR_WAN=10
TIME_TO_WAIT_FOR_RPC_SERVER=5
TIME_TO_WAIT_PER_LOOP=5 # Use higher integer number to limit resource consumption
TIME_AFTER_EXPECTED_TO_WAIT_FOR_BLOCK=30 
MAX_BLOCKS_TO_WAIT_BEFORE_RESTARTING_NODE=3 # Retarts after n blocks if not recieving new blocks even if chatting P2P

# Set logging mode
LOG_INTERVAL=30 # Will never log more frequent than TIME_TO_WAIT_PER_LOOP set above

# Init global vars
LAST_LOG_TIME=0
LAST_BLOCK=0
LAST_P2P_COUNTER=0
LAST_LOOP_TIME=0
LAST_BLOCK_BEHIND=$MAX_BLOCKS_TO_WAIT_BEFORE_RESTARTING_NODE
SLEEPTIME=0
BLOCKCACHE=() # Array of json strings; internal [0] and external [1] raw blockheader
CONSTANTSCACHE=() # Array of json strings; internal [0] and external [1] raw constants

# Define generic functions
now(){ echo $(date +"%s"); } # Get unix timestamp
calc(){ echo "$1" | bc; } # Evaluate string as arithmetic expression 
clean(){ tmp="${1%\"}"; tmp="${tmp#\"}"; echo "$tmp"; }
inString() { [ -z "${2##*$1*}" ] && [ -z "$1" -o -n "$2" ] && return 0 || return 1; }
shortenHash(){ echo "${1::5}"..."${1: -5}"; }

# Define network functions
networkon(){ [ $(cat /sys/class/net/$NETWORK_INTERFACE/operstate) == "up" ] && return 0 || return 1; }
pingconnected(){ networkon && ping -q -c 1 -W 2 8.8.8.8 >/dev/null && return 0 || return 1; }
vpnon(){ [ $(nmcli c show --active | grep $VPN_INTERFACE | wc -l) -eq 1 ] && return 0 || return 1; }
vpn(){ vpnon && pingconnected && return 0 || return 1; }
internetconnected(){ curl -m 1 -sf http://google.com > /dev/null && return 0 || return 1; }

# Define RPC checking functions
rpcup(){ [ -z "$1" ] && RPC_URI=$RPC_INT_URI || RPC_URI=$RPC_EXT_URI; local tmp=$(curl -s $RPC_URI/chains/main/blocks/head/header); [ "${#tmp}" -gt 0 ] && ! inString "Connection refused" "$tmp" && return 0 || return 1; }
extrpcup(){ $(rpcup "ext") && return 0 || return 1; }

# Define P2P functions
getNetworkStat(){ echo $(curl -s $RPC_HOST:$RPC_PORT/network/stat) && return 0 || return 1; }
getNetworkStatInfo(){ echo $(clean $(getNetworkStat) | jq ."$1") && return 0 || return 1; }
getCurrentInflowP2P(){ echo $(clean $(getNetworkStatInfo current_inflow)) && return 0 || return 1; }
isRecievingP2P(){ [[ $(getCurrentInflowP2P) > 0 ]] && return 0 || return 1; }
getCurrentOutflowP2P(){ echo $(clean $(getNetworkStatInfo current_outflow)) && return 0 || return 1; }
isSendingP2P(){ [[ $(getCurrentOutflowP2P) > 0 ]] && return 0 || return 1; }
isChattingP2P(){ isRecievingP2P && isSendingP2P  && return 0 || return 1; }
isP2PThresholdMet(){ [ $(calc $(getCurrentInflowP2P)+$(getCurrentOutflowP2P)) -gt $P2P_THRESHOLD ] && return 0 || return 1; }
getCurrentP2PRate(){ echo $(calc "scale=2;($(getCurrentOutflowP2P)+$(getCurrentOutflowP2P))/1024" ) && return 0 || return 1; }
getTotalTxp2p(){ rpcup && echo $(calc "$(clean $(getNetworkStatInfo total_recv))+$(clean $(getNetworkStatInfo total_sent))"); }

# Define block related functions - note functions return -1 if unable to get RPC data
getBlockHeader(){ [ -z "$1" ] && RPC_URI=$RPC_INT_URI || RPC_URI=$RPC_EXT_URI ; echo $(curl -s $RPC_URI/chains/main/blocks/head/header) && return 0 || return 1; } # Will use external RPC if called with paramter
getBlockHeaderExternal(){ echo $(getBlockHeader "ext") && return 0 || return 1; }
updateBlockHeaderCache(){ [ -z "$1" ] && cacheIndex=0 && tmp=$(getBlockHeader); ! [ -z "$1" ] && cacheIndex=1 && tmp=$(getBlockHeaderExternal); [ "${#tmp}" -gt 1 ] && ! inString "Connection refused" "$tmp" && BLOCKCACHE[$cacheIndex]=$tmp && return 0 || return 1; }
updateBlockHeaderCacheExternal(){ updateBlockHeaderCache "ext" && return 0 || return 1; }
updateAllBlockheaderCaches(){ updateBlockHeaderCache && updateBlockHeaderCacheExternal && return 0 || return 1; }
emptyAllBlockHeaderCaches(){ CACHE=() && return 0 || return 1; }
isInternalBlockHeaderCacheSet(){ ! [ -z "${BLOCKCACHE[0]}" ] && return 0 || return 1; }
isExternalBlockHeaderCacheSet(){ ! [ -z "${BLOCKCACHE[1]}" ] && return 0 || return 1; }
getBlockHeaderInfo(){ [ -z "$2" ] && cacheIndex=0 || cacheIndex=1 ; isInternalBlockHeaderCacheSet && echo $(echo "${BLOCKCACHE[$cacheIndex]}" | jq ."$1") && return 0 || return 1; } 
getBlockHeaderInfoExternal(){ isExternalBlockHeaderCacheSet && echo $(getBlockHeaderInfo "$1" "ext") && return 0 || return 1;  }
getTimeSinceLastBlock(){ isInternalBlockHeaderCacheSet && echo $(calc "$(date +"%s")"-"$(date -d "$(clean $(getBlockHeaderInfo timestamp))" +"%s")") && return 0 || return 1; }
getTimeSinceLastBlockExternal(){ isExternalBlockHeaderCacheSet && echo $(calc "$(date +"%s")"-"$(date -d "$(clean $(getBlockHeaderInfo timestamp "ext"))" +"%s")") && return 0 || return 1; }

getBlockHash(){ tmp=$(clean $(getBlockHeaderInfo hash)); [ "${#tmp}" -gt 0 ] && echo "$tmp" && return 0 || return 1; }
getBlockHashExternal(){ echo $(clean $(getBlockHeaderInfoExternal hash "ext")) && return 0 || return 1; }
getBlockLevel(){ tmp=$(clean $(getBlockHeaderInfo level)); [ "${#tmp}" -gt 0 ] && echo "$tmp" && return 0 || return 1; }
getBlockPriority(){ tmp=$(clean $(getBlockHeaderInfo priority)); [ "${#tmp}" -gt 0 ] && echo "$tmp" && return 0 || return 1; }
getBlockLevelExternal(){ echo $(clean $(getBlockHeaderInfoExternal level "ext")) && return 0 || return 1; }
getBlockProtocol(){ tmp=$(clean $(getBlockHeaderInfo protocol)); [ "${#tmp}" -gt 0 ] && echo "$tmp" && return 0 || return 1; }
getBlockProtocolExternal(){ echo $(clean $(getBlockHeaderInfo protocol "ext")) && return 0 || return 1; }
getBlockDateTime(){ tmp=$(clean $(getBlockHeaderInfo timestamp)); [ "${#tmp}" -gt 1 ] && echo "$tmp" && return 0 || return 1; }
getBlockDateTimeExternal(){ echo $(clean $(getBlockHeaderInfoExternal timestamp "ext")) && return 0 || return 1; }

# Define protocol constants related functions - note functions return -1 if unable to get RPC data
getProtocolConstants(){ [ -z "$2" ] && RPC_URI=$RPC_INT_URI || RPC_URI=$RPC_EXT_URI; rpcup && echo $(curl -s $RPC_URI/chains/main/blocks/$(getBlockLevel)/context/constants | jq ."$1") && return 0 || return 1; }
getProtocolConstant(){ [ -z "$2" ] && RPC_URI=$RPC_INT_URI || RPC_URI=$RPC_EXT_URI; rpcup && echo $(curl -s $RPC_URI/chains/main/blocks/$(getBlockLevel)/context/constants | jq ."$1") && return 0 || return 1; }
updateProtocolConstantCache(){ tmp=$(getProtocolConstants) && [ "${#tmp}" -gt 1 ] && CONSTANTSCACHE[0]=$tmp && return 0 || return 1; }
getTimeBetweenBlocks(){ tmp=$(getProtocolConstant "time_between_blocks"); [ "${#tmp}" -gt 1 ] && echo "$tmp" && return 0 || return 1; }
getMinimalBlockDelay(){ tmp=$(clean $(getProtocolConstant "minimal_block_delay")); [ "${#tmp}" -gt 1 ] && echo "$tmp"; return 0 || return 1; }

# Define logging functions
log(){ echo "$1"; }
logamber(){ local AMBER='\033[0;33m'; local NC='\033[0m'; echo -e "${AMBER}$1${NC}"; }
logred(){ local RED='\033[1;31m'; local NC='\033[0m'; echo -e "${RED}$1${NC}"; } # Use \x1B instead of \033 if on Mac
logNodeOK(){ log "Node OK | Block \"$(shortenHash $(getBlockHash))\" | Level $(getBlockLevel) | Priority $(getBlockPriority) | $(getTimeSinceLastBlock) secs ago | Traffic: $(getCurrentP2PRate) KB/s" && return 0 || return 1; }
logBlockNonZeroPrio(){ logamber "$(logNodeOK)"; }
logNodeBehind(){ logred "BEHIND | Block \"$(shortenHash $(getBlockHash))\" | Level $(getBlockLevel) | Priority $(getBlockPriority) | $(getTimeSinceLastBlock) secs ago | Traffic: $(getCurrentP2PRate) KB/s" && return 0 || return 1; }
logBlockDelayed(){ logred "$(logNodeOK)" && return 0 || return 1; }

isLocalNodeLagging(){ [ $(getBlockLevelExternal) -gt $(getBlockLevel) ] && return 0 || return 1; }

# Give the tezos deamon a chance to start up properly
if [ $(date +"%s") -lt $((LAST_REBOOT+TIME_TO_WAIT_AFTER_REBOOT)) ]; then sleep $TIME_TO_WAIT_AFTER_REBOOT; fi

#$LOG_VERBOSE && echo "Verbose loggin on - will log every $TIME_TO_WAIT_PER_LOOP secs if possible"
[ $TIME_TO_WAIT_PER_LOOP -gt $LOG_INTERVAL ] && logred "Warning: Log interval < loop interval. Will log every $TIME_TO_WAIT_PER_LOOP secs instead of every $LOG_INTERVAL secs" 

while true; do
	# Resetting timers/monitors
	LAST_LOOP_TIME=$(now);
	
	# Activating local area networking if needed
	if $FORCE_LAN && ! networkon || $FORCE_LAN && ! pingconnected; then
		logred "LAN required but not functional --> Starting LAN ($NETWORK_INTERFACE)"
		nmcli networking on ; $ALLOW_WIFI && nmcli radio all on ; ! $ALLOW_WIFI && nmcli radio all off ;  # Toggling wifi 
		sleep "$TIME_TO_WAIT_FOR_LAN"	
	fi
	
	# Restarting VPN if needed
	if $FORCE_VPN && ! vpnon || $FORCE_VPN && ! vpn ; then
		logred "VPN required but not functional --> Starting VPN ($VPN_INTERFACE)"
		systemctl reload-or-restart openvpn-client@pia.service # Replace with your own VPN command
		sleep "$TIME_TO_WAIT_FOR_VPN" && continue
	fi
	# WAN restart not yet implemented

	# Check if RPC server is available. Else give time to start. Check again.
	if ! updateBlockHeaderCache && sleep $TIME_TO_WAIT_FOR_RPC_SERVER && ! updateBlockHeaderCache; then 
		logred "RPC required but not functional --> Re-starting tezos-node (RPC = $RPC_INT_URI) (Allowing $TIME_TO_WAIT_AFTER_NODE_RESTART secs)"
		systemctl reload-or-restart tezos-node.service 
		sleep "$TIME_TO_WAIT_AFTER_NODE_RESTART" && continue
	fi

	# Log current protocol
	[ $LAST_BLOCK -eq 0 ] && isInternalBlockHeaderCacheSet && log "Protocol: $(getBlockProtocol)" && LAST_LOG_BLOCK_LEVEL=$(getBlockLevel);
	
	# Check if node is running as it should		
	if isInternalBlockHeaderCacheSet && [ $(getTimeSinceLastBlock) -gt $(calc $(getMinimalBlockDelay)+$TIME_AFTER_EXPECTED_TO_WAIT_FOR_BLOCK) ] ; then
		#$LOG_VERBOSE || [ $(calc $LAST_LOG_TIME+$LOG_INTERVAL) -lt $(now) ] && logred "Time since last block threshold of $(calc $(getMinimalBlockDelay)+$TIME_AFTER_EXPECTED_TO_WAIT_FOR_BLOCK) secs exceeded --> checking external node"
		if updateBlockHeaderCacheExternal ; then 
			if isP2PThresholdMet && ! isLocalNodeLagging ; then 
				[ $(calc $LAST_LOG_TIME+$LOG_INTERVAL) -lt $(now) ] && logBlockDelayed && LAST_LOG_TIME=$(now)
			elif isP2PThresholdMet && isLocalNodeLagging ; then # Find out if node is falling further behind
				[ $(calc $LAST_LOG_TIME+$LOG_INTERVAL) -lt $(now) ] && logNodeBehind && LAST_LOG_TIME=$(now)
			elif ! isP2PThresholdMet ; then 
				logred "Local node not getting P2P --> Re-starting tezos-node (RPC = $RPC_INT_URI)"
				systemctl reload-or-restart tezos-node.service
				sleep $TIME_TO_WAIT_AFTER_NODE_RESTART 
			else 
				logred "Could not verify current network block level using $RPC_EXT_URI!"
			fi
		fi
	elif isP2PThresholdMet ; then
		[ $(getBlockPriority) -eq 0 ] && [ $LAST_BLOCK -lt $(getBlockLevel) ] && rpcup && logNodeOK && LAST_LOG_TIME=$(now)
		[ $(getBlockPriority) -ne 0 ] && [ $LAST_BLOCK -lt $(getBlockLevel) ] && rpcup && logBlockNonZeroPrio && LAST_LOG_TIME=$(now)
	fi

	# Empty caches & Pause until next loop
	LAST_BLOCK=$(getBlockLevel)
	emptyAllBlockHeaderCaches; 

	TIME_TO_NEXT_LOOP=$(calc "$TIME_TO_WAIT_PER_LOOP"-$(calc "$(now)-$LAST_LOOP_TIME"))
	[ $TIME_TO_NEXT_LOOP -gt 0 ] && sleep $TIME_TO_NEXT_LOOP;

done	

logred "Could not reach or start RPC server. Exiting!"
exit 1; 

