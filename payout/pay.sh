#!/bin/bash
#set -eux

if [ $# -ne 2 ]; then
    echo "You need to provide from and to cycles as two separate arguments when calling the script"
    exit 1
fi

# API Documentation
# https://tzstats.com/docs/api#income-table
# https://tzstats.com/docs/api#snapshot-table

# INPUT VARIABLES
CYCLE_FROM=$1
CYCLE_TO=$2

# CONSTANTS
API_URL="https://api.tzstats.com"
BAKER="<YOURBAKERPHK>"
FEE=0.2
OUTPUT_FILE="tmp-$CYCLE_FROM-$CYCLE_TO.csv"

# FUNCTIONS
clean(){ tmp="${1%\"}"; tmp="${tmp#\"}"; echo "$tmp"; }
calc(){ echo "$1" | bc; } # Evaluate string as arithmetic expression 
calcfloat(){ echo "$1" | bc -l; }

# Payout addresses
PAYPKH="<ANY LIST OF PHK YOU WANT TO PAYOUT FOR OR LEAVE THIS AND DELETE LINES 67 AND 69-71>"

# MAIN
i=$CYCLE_FROM

# Print header for CSV file
echo "Cycle;Address;RewardShare;Reward;PayOut;Fee" > $OUTPUT_FILE

while [ $i -le $CYCLE_TO ] ; do
	# Get total baker rewards for cycle
	BUF=$(curl -s "$API_URL/tables/income?address=$BAKER&cycle=$i&columns=total_income,total_loss,balance,delegated")
	total_income=$(echo "$BUF" | jq '.[0][0]') 
  total_lost=$(echo "$BUF" | jq '.[0][1]') 
  total_rewards=$(calcfloat "$total_income-$total_lost")
	baker_balance=$(echo "$BUF" | jq '.[0][2]') 
  baker_delegated=$(echo "$BUF" | jq '.[0][3]')
	baker_total=$(calc "$baker_balance+$baker_delegated") 
	# Get delegates for cycle when rewards were earned
		BUF=$(curl -s "$API_URL/tables/snapshot?baker=$BAKER&cycle=$i&is_selected=1&columns=address,balance")
		f=0
		for field in $(echo "$BUF" | jq -r '.[][]'); do
			f=$((f += 1))
			if [ $(expr $f % 2) != "0" ]; then
				delegate="$field"
			else
				delegate_balance="$field"
				delegate_rewardshare=$(calcfloat "$delegate_balance/$baker_total")
				delegate_reward=$(calcfloat "$delegate_rewardshare*($total_rewards)")
				delegate_fee=$(calcfloat "$delegate_reward*$FEE")
				delegate_payout=$(calcfloat "$delegate_reward-$delegate_fee")
				if [[ "$PAYPKH" == *"$delegate"* ]]; then
					strout="$i;$delegate;$delegate_rewardshare;$delegate_reward;$delegate_payout;$delegate_fee"
                                else
					strout="$i;$delegate;$delegate_rewardshare;$delegate_reward;$delegate_reward;0"
                                fi
				#echo "$i;$delegate;$delegate_rewardshare;$delegate_reward;$delegate_payout;$delegate_fee" >> $OUTPUT_FILE
				echo "$strout"  >> $OUTPUT_FILE
			fi
		done
	i=$((i += 1))
done
