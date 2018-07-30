## Intro to using VPN via systemd

I have had several requests on how to employ openvpn as a service for running Tezos over VPN. Specifically one example was requested for PIA (www.privateinternetaccess.com). So here goes one example which uses PIA as commercial VPN provider - this is just one example, each provider will have their own examples for you to use.

First install openvpn: ```sudo apt-get install openvpn```

Then verify that your ```/lib/systemd/system/openvpn-client@.service``` looks like this:<br>
```
[Unit]
Description=OpenVPN tunnel for %I
After=syslog.target network-online.target
Wants=network-online.target
Documentation=man:openvpn(8)
Documentation=https://community.openvpn.net/openvpn/wiki/Openvpn24ManPage
Documentation=https://community.openvpn.net/openvpn/wiki/HOWTO

[Service]
Type=notify
PrivateTmp=true
WorkingDirectory=/etc/openvpn/client
ExecStart=/usr/sbin/openvpn --suppress-timestamps --nobind --config %i.conf
CapabilityBoundingSet=CAP_IPC_LOCK CAP_NET_ADMIN CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_SYS_CHROOT CAP_DAC_OVERRIDE
LimitNPROC=10
DeviceAllow=/dev/null rw
DeviceAllow=/dev/net/tun rw
ProtectSystem=true
ProtectHome=true
KillMode=process

[Install]
WantedBy=multi-user.target
```

Now we want to create the file that openvpn will read as ´%I´ - for example `pia.conf` for `openvpn-client@pia.service`<br>
The below files will use PIA as VPN provider and force strong encryption - less would often be enough, but let's go all in...
- [x] pia.conf 
- [x] credentials 
- [x] ca.rsa.4096.crt 
- [x] crl.rsa.4096.pem

You can download the first and the last two files from: [https://www.privateinternetaccess.com/openvpn/openvpn-strong.zip](https://www.privateinternetaccess.com/openvpn/openvpn-strong.zip) and you can read more about VPN encryption here: [https://www.privateinternetaccess.com/pages/vpn-encryption](https://www.privateinternetaccess.com/pages/vpn-encryption)

The `pia.conf` file is the openvpn client configuration file for PIA - you might want to edit that one. See below.
the `credentials` file simply contains two lines, the first one is your userid, then second one is your password. You get these credentials from your VPN provider. You definitively want to edit this file.
The `ca.rsa.4096.crt` and `crl.rsa.4096.pem` files are the PIA certificate files. You do not want to edit these files!

Let us have a look at the `pia.conf` file for use with PIA - you want to do other `.conf` files for other providers. The above link for PIA .conf files contain a wide range of such files.

### pia.conf 
##### This axample uses a VPN server loaction in Holland - whereby the Tezos Node would appear to be located there
```
client
dev tun
proto udp
remote nl.privateinternetaccess.com 1197
resolv-retry infinite
nobind
persist-key
persist-tun
cipher aes-256-cbc
auth sha256
tls-client
remote-cert-tls server

auth-user-pass /etc/openvpn/client/credentials
comp-lzo
verb 1
reneg-sec 0
crl-verify crl.rsa.4096.pem
ca ca.rsa.4096.crt
disable-occ
```

Notice that the line `auth-user-pass` is where you put the location for your credentials file. Make sure this file is only readable by root.
The `disable-occ`  option may not be strictly needed in most cases, you can try and leave it out. See [https://openvpn.net/index.php/open-source/documentation/manuals/65-openvpn-20x-manpage.html](https://openvpn.net/index.php/open-source/documentation/manuals/65-openvpn-20x-manpage.html) for details.

Now create `/etc/openvpn/client/credentials` (or whereever you put it) with two lines in it: userid (line 1) password (line 2).

That's it! 

We are ready to launch the VPN service:<br>`sudo systemctl start openvpn-client@pia.service`

We can install it to load on boot:<br>`sudo systemctl enable openvpn-client@pia.service`

We can stop it:<br>`sudo systemctl stop openvpn-client@pia.service`

We can restart it after having replaced the pia.conf file, e.g. to start baking in another country:<br>`sudo systemctl reload-or-restart openvpn-client@pia.service`

We can monitor it:<br>`sudo systemctl status openvpn-client@pia.service`

We can disable it so it doesn't load at boot time:<br>`sudo systemctl stop openvpn-client@pia.service`

### With these few simple steps you have just enhanced the resilience of your Tezos node/baker. 

In case you get ddos'ed you simply replace the VPN server location in the `.conf` file and reload your VPN service. Gone are the attackers - ready is your baker. This can obviously be automated, but it is beyond the scope of this file. Generally, you would be a very large baker to be a big enough target for anyone to try and ddos a big commercial VPN provider. 

More importantly, you are now protecting the identity of your node and yourself a lot more than before. 

Happy baking!
