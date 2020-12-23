## Tezos Node CPR

Rarely, your Tezos node may need cardiopulmonary resuscitation (CPR) - or simply a restart - to function properly. 
One reason could be a prolonged period without network connectivity. 

#### Below is a script to help you automate this process. 
It is a simple bash script. It is meant to run as a service, but you can just as well run it manually if you like. 
As a standard it does not log to a file, but you can just add/edit a line in the `log()` function to do that.

*For the script to easily parse json it uses python3 - so you need to have that installed. Ubuntu ships with it.*

You can configure the following parameters (simply edit the script) to your liking:
- [ ] NETWORK_INTERFACE
- [ ] TIME_TO_WAIT_FOR_NETWORK
- [ ] TIME_TO_WAIT_AFTER_RESTART
- [ ] TIME_TO_RETRY_P2P
- [ ] TIME_TO_WAIT_FOR_P2P
- [ ] TIME_TO_WAIT_FOR_BLOCK
- [ ] TIME_TO_WAIT_FOR_BLOCK_MAX

You may also configure these parameters:
- [x] RPC_HOST=127.0.0.1
- [x] RPC_PORT=8732

But I do recommend that you leave them be unless you are running an advanced setup.

You would want to test the script first after having reviewed it and then install it as a service.

#### The script itself looks like this
```bash
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
TIME_TO_WAIT_FOR_BLOCK_MAX=600

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
			if [ $(networkconnected) ] && [ $(rpcserverrunning) ] && [ $P2P_TX_TOTAL -lt $(getTotalTxp2p) ] && [ $(getTimeSinceLastBlock) -le $TIME_TO_WAIT_FOR_BLOCK_MAX ] ; then
				echo $(log "Found p2p activity")
			else
				# Network OK. No p2p activity and/or (too) old block header. Restarting node. Check connection first.
				if [ $(networkconnected) ] && [ $(pingconnected) ] && [ $(internetconnected) ] ; then				
					echo $(log "Network OK. No p2p activity and/or too long ($(getTimeSinceLastBlock) secs since last block. Restarting node!")
					#You may want to restart your VPN services as well?
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
```

#### You may want to tailor your own restart command(s)
For that you just edit the section with the current restart command `systemctl reload-or-restart tezos-node.service` and change it to whatever you want.

*Remember: you need to run this as a user priviledge enough to control systemd (e.g. root) if you have installed it as a service*
*If you do it manually you can run it as the same user you run your Tezos node as*

### Running the script
You would want to make sure the script is running. You can start it manually `./tezos-node-cpr.sh` (after having done `chmod +x tezos-node-cpr.sh`, as a cron job or install it as a service. For the latter you would want to do a service that looks something like this:

```
# The Tezos Node CPR service (part of systemd)
# file: /etc/systemd/system/tezos-node-cpr.service 

[Unit]
Description     = Tezos Node Moitoring and Restarting Service
Wants           = network-online.target tezos-node.service
After           = tezos-node.service

[Service]
WorkingDirectory= /home/baker/
ExecStart       = /home/baker/tezos-node-cpr.sh
Restart         = on-failure

[Install]
WantedBy	= multi-user.target
```

Since journalctl adds its own timestamp to reported events, one might want to remove the timestamp from the `log()` function in this script:
```
log(){ echo "$1"; }
```
