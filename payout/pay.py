import sys, json, urllib
from urllib import urlopen

cycle_from = int(sys.argv[1])
cycle_to = int(sys.argv[2])+1

api_server	= "https://api.tzstats.com"

baker_pkh	= "<insertbakerpkhhere>"	# set address
fee_percent	= 20.0				# delegation service fee

# Go through cycles one by one
for i in range(cycle_from, cycle_to):
	# Get total baker rewards for cycle
	url_api = api_server+"/tables/income?cycle=" + str(i) + "&address=" + str(baker_pkh) + "&columns=total_income,total_lost,delegated"
	response = urllib.urlopen(url_api)
	data = json.loads(response.read().decode("utf-8"))
	total_income =  float(data[0][0])
	total_lost = float(data[0][1])
	total_delegated = float(data[0][2])
	total_rewards = total_income - total_lost 
	# Get delegates for cycle
	url_api = api_server+"/tables/snapshot?delegate="+baker_pkh+"&cycle="+str(i)+"&is_selected=1&columns=address,balance,cycle"
	response = urllib.urlopen(url_api)
	data = json.loads(response.read().decode("utf-8"))
	for delegate in data: 
		delegate_pkh = delegate[0]
		void_fee = int(delegate_pkh == baker_pkh)
		delegate_balance = delegate[1]
		delegate_rewardshare = delegate_balance/total_delegated  
		delegate_rewards = total_rewards * delegate_rewardshare * (100 - fee_percent * void_fee)/100  
		print '{};{};{};{}%;{}:'.format(i, delegate_pkh, total_rewards, delegate_rewardshare * 100, delegate_rewards)
