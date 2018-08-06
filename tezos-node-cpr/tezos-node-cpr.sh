#!/bin/sh
#set -eux

echo "Starting the tezos-node-cpr.sh v 0.1 (etomknudsen, August 2018)"

# Get timestamp for last reboot
LAST_REBOOT=$(date -d "$(who -b | cut -c22-38)" +"%s")

# Networking interface
# Use "ls -la /sys/class/net/" to see which devices you have avaiable
NETWORK_INTERFACE="enp1s0" 
#NETWORK_INTERFACE="wlp2s0"

# Set RPC parameters
RPC_HOST=127.0.0.1
RPC_PORT=8732

# Set timeouts (seconds) 
TIME_TO_WAIT_AFTER_REBOOT=5
TIME_TO_WAIT_FOR_NETWORK=10
TIME_TO_WAIT_AFTER_RESTART=60
TIME_TO_WAIT_FOR_RPC_SERVER=30
TIME_TO_RETRY_P2P=10
TIME_TO_WAIT_FOR_P2P=90
TIME_TO_WAIT_FOR_BLOCK=180

# Give the tezos deamon a chance to start up properly
if [ $(date +"%s") -lt $(($LAST_REBOOT+$TIME_TO_WAIT_AFTER_REBOOT)) ]; then
	sleep $TIME_TO_WAIT_AFTER_REBOOT
fi

# Define functions
getLastBlockHeaderInfo(){ echo $(curl -s $RPC_HOST:$RPC_PORT/chains/main/blocks/head/header | python3 -c "import sys, json; print(json.load(sys.stdin)['$1'])"); }
getTimeSinceLastBlock(){ echo $(($(date +"%s")-$(date -d $(getLastBlockHeaderInfo timestamp) +"%s"))); }
getTotalTxp2p(){ echo $(curl -s $RPC_HOST:$RPC_PORT/network/stat | python3 -c "import sys, json; array = json.load(sys.stdin); print(int(array['total_recv'])+int(array['total_sent']))"); }
networkconnected(){ if [ $(cat /sys/class/net/$NETWORK_INTERFACE/operstate) = up ]; then echo true; fi }
pingconnected(){ if ping -q -c 1 -W 1 8.8.8.8 >/dev/null; then echo true; else echo false; fi }
internetconnected(){ if curl -sf http://google.com > /dev/null; then echo true; else echo false; fi }
rpcserverrunning(){ if curl -s $RPC_HOST:$RPC_PORT/chains/main/blocks/head/header >/dev/null; then echo true; fi }
log(){ echo "$(date -u +"%Y-%m-%dT%TZ") $1"; }

# Check if RPC server is available else give it time to start (assuming tezos is running as a service)
if [ ! $(rpcserverrunning) ]; then wait $TIME_TO_WAIT_FOR_RPC_SERVER; fi

# Check if RPC server is available else exit
if [ $(rpcserverrunning) ]; then
	while true; do
	P2P_TX_TOTAL=$(getTotalTxp2p)
		# If we have had a new block within the defined waiting time then everything is fine
		if [ $(networkconnected) ] && [ $(rpcserverrunning) ] && [ $(getTimeSinceLastBlock) -le $TIME_TO_WAIT_FOR_BLOCK ]; then
			echo $(log "$(getLastBlockHeaderInfo hash) @ $(getLastBlockHeaderInfo timestamp) ($(getTimeSinceLastBlock) secs ago)")
			P2P_TX_TOTAL=$(getTotalTxp2p)
			sleep $TIME_TO_WAIT_FOR_P2P
		else
			# No new block(s) within the defined waiting time; Wait for p2p traffic. If p2p is active; dont panic
			if [ $(networkconnected) ] && [ $(rpcserverrunning) ]; then 
				echo $(log "Looking for p2p avtivity - will wait for max $TIME_TO_WAIT_FOR_P2P secs"); 
				TIMEOUT_WAIT_FOR_P2P=$(($(date +"%s")+$TIME_TO_WAIT_FOR_P2P));
				# Keep looking for new p2p activity until timeout or activity detected
				while [ $(date +"%s") -lt $TIMEOUT_WAIT_FOR_P2P ] && [ $(networkconnected) ] && [ $(rpcserverrunning) ] && [ $P2P_TX_TOTAL -eq $(getTotalTxp2p) ]; do
					echo $(log "Waiting. Last block was $(getTimeSinceLastBlock) secs ago)")					
					sleep $TIME_TO_RETRY_P2P
				done
			fi
			if [ $(networkconnected) ] && [ $(rpcserverrunning) ] && [ $P2P_TX_TOTAL -lt $(getTotalTxp2p) ]; then
				echo $(log "Found p2p activity")
			else
				# Network OK. No p2p activity. Old block header. Restarting node. But check connection first
				if [ $(networkconnected) ] && [ $(pingconnected) ] && [ $(internetconnected) ] ; then				
					echo $(log "Network OK. No p2p activity. Too long ($(getTimeSinceLastBlock) secs) since last block. Restarting node!")
					systemctl reload-or-restart tezos-node
					P2P_TX_TOTAL=0
					sleep $TIME_TO_WAIT_AFTER_RESTART
				else
					# Network connection has been lost
					echo $(log "No network ($NETWORK_INTERFACE)")
					sleep $TIME_TO_WAIT_FOR_NETWORK
				fi
			fi
		fi
	done
else
	# No connection to RPC server. Exiting.
	exit 1
fi

