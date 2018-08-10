## Tezos baking tools to ease a bakers life<br>Focus on uptime and ease of use / monitoring

If you own Tezos tokens (XTZ), you want them to work for the Tezos network and ecosystem. 
It is a fun challenge and you will be rewarded for doing it. The more individual bakers we have in the Tezos ecosystem the more decentralized and resilient Tezos will become.  

Granted, it takes a little bit of work - but good guides exist and I think you will find it worth while. This repository focuses on getting you maximal uptime and ease of use once you have installed your node(s) and gotten your ledger to work. 

To spin up a node use this excellent guide: https://github.com/tezoscommunity/FAQ/blob/master/Compile_Betanet.md

To get your Ledger Nano S to work with Tezos follow this excellent guide: https://github.com/obsidiansystems/ledger-app-tezos/blob/master/README.md

## Using systemd to control and monitor your node, baker, endorser and accuser

If you are not familiar with "services" or systemd there is a good intro here: https://www.digitalocean.com/community/tutorials/how-to-use-systemctl-to-manage-systemd-services-and-units

Briefly, what we want is a stable system with maximal uptime in return for minimal intervention. As such we need a tezos node that starts itself once the system boots and a baker/endorser/accuser that is always on and ready to bake/endorse/accuse. `systemd` can easily help us achieve this. 

Below you'll find the config files for such a system together with some explanation of how it works. 

Basically, for a full bakery we want to configure and (auto-)run four services
- [x] Tezos Node
- [x] Tezos Baker
- [x] Tezos Endorser
- [x] Tezos Accuser

For a node only, the bottom of this page has instructions on how to use `systemd` to run a non-baking node. It is super easy. If you only need that then you can read the `tezos-node.service` part and then skip to the bottom of the document. 

The individual files for a full bakery are outlined below. You can copy and paste them into the paths/files mentioned in each section. 

For monitoring the daemons you can use `journalctl` which is a powerful tool to monitor services both real-time and after the fact. 
There is separate section on this towards the end of this document; go there now by clicking [this link] () 
  
#### tezos-node.service

First we want to set up the service to run our Tezos node. The below example includes running over VPN - you dont have to, just remove the `openvpn-client@<vpnprovider>.service` under the `[Unit]` both for `Wants` and `After`. 

At the `ExecStart` line you can place whatever command you normally use to start your node - just dont use nohub etc. You can (& should) change your `user`and `group` to whatever you use on your system. I control my nodes in a simple config.json - but the below should work with default settings all over. 

```
# The Tezos Node service (part of systemd)
# file: /etc/systemd/system/tezos-node.service 

[Unit]
Description     = Tezos Node Service
Documentation   = http://tezos.gitlab.io/betanet/
Wants           = network-online.target openvpn-client@<vpnprovider>.service
After           = network-online.target openvpn-client@<vpnprovider>.service 

[Service]
User            = baker
Group		= baker
WorkingDirectory= /home/baker/
ExecStart	= /home/baker/tezos/tezos-node run --bootstrap-threshold=1
Restart         = on-failure

[Install]
WantedBy	= multi-user.target
RequiredBy	= tezos-baker.service tezos-endorser.service tezos-accuser.service
```

To install your tezos node as a service that loads at boot time you use systemctl:<br>
```sudo systemctl enable tezos-node.service```<br>

*Notice that we use `After` to tell systemd that this service should be loaded after networking is established. We allow the tezos-node service to load without network by using `Wants` as we might establish network later. You can make sure the tezos node would only load once network is established by chainging 'Wants' to 'Requires' but I would recommend against doing so, as it limits your flexibility. Same with the VPN service*

To start your tezos node service you would use:<br>
```sudo systemctl start tezos-node.service```
*Obviously, you rarely use this command unless you 1) havent rebooted your system after installing the service or 2) you have actively shut down the service*

To start your tezos node service I strongly recommend you use the `reload-or-restart` instead, as this would ensure (via systemd) that the service is started if not running already and reloaded if already running:<br>
```sudo systemctl reload-or-restart tezos-node.service```

To see the status of your tezos node service you would use:<br>
```sudo systemctl status tezos-node.service```

To stop your tezos node service you would use:<br> 
```sudo systemctl stop tezos-node.service```

If for some reason you don't want the node to start at boot anymore, simply do:<br>
```sudo systemctl disable tezos-node.service```

#### tezos-baker.service

Now that the node is up and running we want to run the baker, endorser and accuser the same way. 

```
# The Tezos Baker service (part of systemd)
# file: /etc/systemd/system/tezos-baker.service 

[Unit]
Description     = Tezos Baker Service
Wants           = network-online.target openvpn-client@<vpnprovider>.service 
BindsTo		= tezos-node.service
After           = tezos-node.service

[Service]
User            = baker
Group		= baker
WorkingDirectory= /home/baker/
ExecStartPre	= /bin/sleep 1
ExecStart       = /home/baker/tezos/tezos-baker-002-PsYLVpVv run with local node /home/baker/.tezos-node ledger_bakerone_ed_0_0
Restart         = on-failure

[Install]
WantedBy	= multi-user.target
```

We know that these services require a tezos node and therefore we require the node to be running first - the hardest form of requirement is binding - this means that this service will only start if the service it `BindsTo` is successfully started and running. Also, if the service (Tezos Node) this service (Tezos Baker) binds to crashes this service will be stopped. 

You should replace the `ExecStart` command with whatever command you want to run your baker with. Also, replace the `ledger_bakerone_ed_0_0` with whatever alias your baking key has. Notice the `ExecStartPre`: It is a little hackish, but I found that introducing a one second delay between starting the node and the baker, endorser and accuser would make the service run smoothly. Else systemd will start them too closely together. There are ways to adjust this using sytemd, but to keep things simple, we simply sleep for a second prior to executing the command to fire up the baker. 

We also know that it would probably be good to reload the baker, endorser and accuser should the node ever reload and therefore we use `BindsTo` to bind these services to the node. This effectively means, that all four services will restart if you restart the node and that you can restart each of the baker, endorser and accuser services seperately, should you need to. 

Same commands as for node to enable, reload/start, stop and get status on the baker:
- ```sudo systemctl enable tezos-baker.service```<br>
- ```sudo systemctl reload-or-restart tezos-baker.service```<br>
- ```sudo systemctl stop tezos-baker.service```<br>
- ```sudo systemctl status tezos-baker.service```<br>

*Note: You must have the Tezos baking app open on your Ledger Nano S when you (re)start your baker and endorser.* 

#### tezos-endorser.service

Now we simply do the same with the endorser and accuser daemons. 

```
# The Tezos Endorser service (part of systemd)
# file: /etc/systemd/system/tezos-endorser.service 

[Unit]
Description     = Tezos Endorser Service
Wants           = network-online.target openvpn-client@<vpnprovider>.service 
BindsTo		= tezos-node.service
After           = tezos-node.service

[Service]
User            = baker
Group		= baker
WorkingDirectory= /home/baker/
ExecStartPre	= /bin/sleep 1
ExecStart       = /home/baker/tezos/tezos-endorser-002-PsYLVpVv run ledger_bakerone_ed_0_0
Restart         = on-failure

[Install]
WantedBy	= multi-user.target
```
Same commands as for node to enable, reload/start, stop and get status on the baker:
- ```sudo systemctl enable tezos-endorser.service```<br>
- ```sudo systemctl reload-or-restart tezos-endorser.service```<br>
- ```sudo systemctl stop tezos-endorser.service```<br>
- ```sudo systemctl status tezos-endorser.service```<br>

*Note: You must have the Tezos baking app open on your Ledger Nano S when you (re)start your baker and endorser.* 

#### tezos-accuser.service

```
# The Tezos Accuser service (part of systemd)
# file: /etc/systemd/system/tezos-accuser.service 

[Unit]
Description     = Tezos Accuser Service
Wants           = network-online.target openvpn-client@<vpnprovider>.service 
BindsTo		= tezos-node.service
After           = tezos-node.service

[Service]
User            = baker
Group		= baker
WorkingDirectory= /home/baker/
ExecStartPre	= /bin/sleep 1
ExecStart       = /home/baker/tezos/tezos-accuser-002-PsYLVpVv run
Restart         = on-failure

[Install]
WantedBy	= multi-user.target
```

Same commands as for node to enable, reload/start, stop and get status on the accuser:
- ```sudo systemctl enable tezos-accuser.service```<br>
- ```sudo systemctl reload-or-restart tezos-accuser.service```<br>
- ```sudo systemctl stop tezos-accuser.service```<br>
- ```sudo systemctl status tezos-accuser.service```<br>

### Combining all the services to get a nice status page for your Tezos operations

```sudo systemctl status tezos-node.service tezos-baker.service tezos-endorser.service tezos-accuser.service```<br>

Or alternatively, shorter but less ordered: 
```sudo systemctl status 'tezos-*.service'```<br>

You can restart all four services by restarting the node (because we bound the baker/endorser/accuser to the node):<br>
```sudo systemctl reload-or-restart tezos-node.service```

Similarly all services will stop upon: <br>
```sudo systemctl stop tezos-node.service```

And you can stop the baker/endorser/accuser individually if you want.
- ```sudo systemctl stop tezos-baker.service```<br>
- ```sudo systemctl stop tezos-endorser.service```<br>
- ```sudo systemctl stop tezos-accuser.service```<br>

### Using front-end nodes and a private baker

The above configurations work for both front end nodes and for baking/endorsing/accusing nodes. If you want to use this (I recommend you do) for your front-end nodes too, simply remove the line `RequiredBy	= tezos-baker.service tezos-endorser.service tezos-accuser.service` from your tezos-node.service and do not install the baker/accuser/endorser services. 

### Restarting your Tezos operations automatically

Above, we use `Restart:on-failure`. You could use `Restart:always` - I just haven't found it neccessary and there is a slight risk that - if combinded with loose restart settings - could exhaust your system. But feel free to try it out if it'll make you sleep better at night. Now that you have all your Tezos operations 'servicified' you can indeed start sleeping at night again, without loosing out on your baking and endorsing slots.

### Setting environment variables in e.g. the baker and endorser to closely monitor your ledger

Just include the following in your [Service] section
`Environment = TEZOS_LOG="client.signer.ledger -> debug"`

If you need to pass a lot of environment variables, use `EnvironmentFile` instead and place one variable per line here. `EnvironmentFile` should point to your file, e.g. /home/baker/tezosenvironmentvariables.

### Using journalctl to monitor the node, baker, endorser and accuser

Sometimes it is neccessary to go through log files to identify root causes for different events and sometimes it is just fun to follow the your Tezos services (=daemons) live. `systemd` has a very powerful tool to do this - it is called `journalctl` and a few examples on how to use it is given below. 

To simply follow your node's output real-time: <br> 
```journalctl --follow --unit=tezos-node.service```

*You dont really need to add the .service - but I'll keep doing it here for clarity*

Similarly with the baker, endorser and accuser:<br>
- ```journalctl --follow --unit=tezos-baker.service```
- ```journalctl --follow --unit=tezos-endorser.service```
- ```journalctl --follow --unit=tezos-accuser.service```

You can also get the output formatted to suit your needs. Try for example:<br>
```journalctl --follow --unit=tezos-endorser.service --output=json-pretty```

Tezos runs its time by the universal timezone 'UTC' to get journalctl to output your log in utc simply add --utc:<br>
```journalctl --follow --unit=tezos-endorser.service --utc```

By now you've probably understood that the possibilities are almost endless and the flexibility is second to none. Try for example to get your log for the endorser after a given timestamp or between two timestamps by doing these:<br>
- ```journalctl --unit=tezos-endorser.service --since=yesterday```
- ```journalctl --unit=tezos-endorser.service --since=today```
- ```journalctl --unit=tezos-endorser.service --since='2018-08-01 00:00:00' --until='2018-08-10 12:00:00' ```

Or find your bakes since last boot:<br>
```journalctl --unit=tezos-baker.service --boot=-0 | grep candidate```

If you have installed/compiled journalctl with pattern matching functionality you can do:<br>
```journalctl --unit=tezos-baker.service --boot=-0 --grep=candidate```

And on and on....

*See more using `man journalctl`*

#### Forget about cron jobs etc - systemd has you covered for some happy hands-off baking...

I've now been asked repeatedly for a donation address. Just glad to help, and donations are not expected. If you feel you want to anyway you can use: [tz1a2oGa6yTXGuS9d9DTckQm5vrh12qYqCqL](https://tzscan.io/tz1a2oGa6yTXGuS9d9DTckQm5vrh12qYqCqL)

Enjoy!

