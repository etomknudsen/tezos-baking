import sys, json, urllib
from urllib import urlopen

cycle_from = int(sys.argv[1])
cycle_to = int(sys.argv[2])+1

api_server      = "https://api.tzstats.com"

baker_pkh       = "<insertbakerpkh>"        # set address
fee_percent     = 20.0                                          # delegation service fee

# Go through cycles one by one
for i in range(cycle_from, cycle_to):
        # Get total baker rewards for cycle
        url_api = '{}/tables/income?address={}&cycle={}&columns=total_income,total_lost,balance,delegated'.format(api_server, baker_pkh, i)
        response = urllib.urlopen(url_api)
        data = json.loads(response.read().decode("utf-8"))
        total_income =  float(data[0][0])
        total_lost = float(data[0][1])
        baker_balance = float(data[0][2])
        baker_delegated = float(data[0][3])
        total_rewards = total_income - total_lost
        # Get delegates for cycle
        print('Cycle;Address;RewardShare;Reward;PayOut;Fee')
        url_api = '{}/tables/snapshot?delegate={}&cycle={}&is_selected=1&columns=address,balance,cycle'.format(api_server, baker_pkh, i-7)
        response = urllib.urlopen(url_api)
        data = json.loads(response.read().decode("utf-8"))
        for delegate in data:
                delegate_pkh = delegate[0]
                void_fee = 1 - int(delegate_pkh == baker_pkh)
                delegate_balance = delegate[1]
                delegate_rewardshare = delegate_balance/(baker_delegated+baker_balance)
                delegate_rewards = total_rewards * delegate_rewardshare
                delegate_fee = delegate_rewards * (100 - fee_percent * void_fee)/100
                delegate_payout = delegate_rewards - delegate_fee
                print '{};{};{}%;{};{};{}'.format(i, delegate_pkh, delegate_rewardshare * 100, delegate_rewards, delegate_fee, delegate_payout)
