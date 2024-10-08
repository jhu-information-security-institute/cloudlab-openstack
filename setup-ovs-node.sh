#!/bin/sh

#
# This sets up openvswitch networks (on neutron, the external and data
# networks).  The networkmanager and compute nodes' physical interfaces
# have to get moved into br-ex and br-int, respectively -- on the
# moonshots, that's eth0 and eth1.  The controller is special; it doesn't
# get an openvswitch setup, and gets eth1 10.0.0.3/8 .  The networkmanager
# is also special; it gets eth1 10.0.0.1/8, but its eth0 moves into br-ex,
# and its eth1 moves into br-int.  The compute nodes get IP addrs from
# 10.0.1.1/8 and up, but setup-ovs.sh determines that.
#

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

logtstart "ovs-node"

#
# Figure out which interfaces need to go where.  We already have 
# $EXTERNAL_NETWORK_INTERFACE from setup-lib.sh , and it and its configuration
# get applied to br-ex .  So, we need to find which interface corresponds to
# DATALAN on this node, if any, and move it (and its configuration OR its new
# new DATAIP iff USE_EXISTING_IPS was set) to br-int
#
EXTERNAL_NETWORK_BRIDGE="br-ex"
#DATA_NETWORK_INTERFACE=`ip addr show | grep "inet $MYIP" | sed -e "s/.*scope global \(.*\)\$/\1/"`
DATA_NETWORK_BRIDGE="br-data"
INTEGRATION_NETWORK_BRIDGE="br-int"

#
# If this is the controller, we don't have to do much network setup; just
# setup the data network with its IP.
#
#if [ "$HOSTNAME" = "$CONTROLLER" ]; then
#    if [ ${USE_EXISTING_IPS} -eq 0 ]; then
#	ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#    fi
#    exit 0;
#fi

#
# Grab our control net info before we change things around.
#
if [ ! -f $OURDIR/ctlnet.vars ]; then
    ctlip="$MYIP"
    ctlmac=`ip -o link show ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*link\/ether \([0-9a-fA-F:]*\) .*$/\1/p'`
    ctlstrippedmac=`echo $ctlmac | sed -e 's/://g'`
    ctlnetmask=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*mask[: ]*\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/ip'`
    ctlgw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    ctlnet=`ip route show dev ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\/[0-9]*\) .*$/\1/p'`
    ctlprefix=`echo $ctlnet | cut -d/ -f2`

    echo "ctlip=\"$ctlip\"" > $OURDIR/ctlnet.vars
    echo "ctlmac=\"$ctlmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlstrippedmac=\"$ctlstrippedmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlnetmask=\"$ctlnetmask\"" >> $OURDIR/ctlnet.vars
    echo "ctlgw=\"$ctlgw\"" >> $OURDIR/ctlnet.vars
    echo "ctlnet=\"$ctlnet\"" >> $OURDIR/ctlnet.vars
    echo "ctlprefix=\"$ctlprefix\"" >> $OURDIR/ctlnet.vars
else
    . $OURDIR/ctlnet.vars
fi

#
# Otherwise, first we need openvswitch.
#
maybe_install_packages openvswitch-common openvswitch-switch

# Make sure it's running
service_restart openvswitch
service_restart openvswitch-switch
service_enable openvswitch
service_enable openvswitch-switch

#
# Setup the external network
#
ovs-vsctl add-br ${EXTERNAL_NETWORK_BRIDGE}
ovs-vsctl add-port ${EXTERNAL_NETWORK_BRIDGE} ${EXTERNAL_NETWORK_INTERFACE}
#ethtool -K $EXTERNAL_NETWORK_INTERFACE gro off

#
# Now move the $EXTERNAL_NETWORK_INTERFACE and default route config to ${EXTERNAL_NETWORK_BRIDGE}
#
grep -q systemd-resolved /etc/resolv.conf
if [ $? -eq 0 ]; then
    if [ -e /var/emulab/boot/bossip ]; then
	DNSSERVER=`cat /var/emulab/boot/bossip`
    else
	DNSSERVER=`resolvectl dns ${EXTERNAL_NETWORK_INTERFACE} | sed -nre 's/^.* ([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*)$/\1/p'`
    fi
else
    DNSSERVER=`cat /etc/resolv.conf | grep nameserver | head -1 | awk '{ print $2 }'`
fi

#
# If we're Mitaka or greater, we have to always re-add our anti-ARP
# spoofing flows on each boot.  See setup-network-plugin-openvswitch.sh
# and the bottom of this script.
#
readdflows=""
if [ $OSVERSION -gt $OSLIBERTY ] ; then
    readdflows='up for line in `cat /etc/neutron/ovs-default-flows/br-ex`; do ovs-ofctl add-flow br-ex $line ; done'
fi

#
# We need to blow away the Emulab config -- no more dhcp
# This would definitely break experiment modify, of course
#
if [ $DISTRIB_MAJOR -lt 18 ]; then
    cat <<EOF > /etc/network/interfaces
#
# Openstack Network Node in Cloudlab/Emulab/Apt/Federation
#

# The loopback network interface
auto lo
iface lo inet loopback

auto ${EXTERNAL_NETWORK_BRIDGE}
iface ${EXTERNAL_NETWORK_BRIDGE} inet static
    address $ctlip
    netmask $ctlnetmask
    gateway $ctlgw
    dns-search $OURDOMAIN
    dns-nameservers $DNSSERVER
    up echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
    up echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
$readdflows

auto ${EXTERNAL_NETWORK_INTERFACE}
iface ${EXTERNAL_NETWORK_INTERFACE} inet static
    address 0.0.0.0
EOF
else
    mv /etc/udev/rules.d/99-emulab-networkd.rules \
        /etc/udev/rules.d/99-emulab-networkd.rules.NO
    systemctl disable emulab-udev-settle.service
    rm -fv \
        /lib/systemd/system/systemd-networkd.socket.requires/emulab-udev-settle-networkd.service \
        /lib/systemd/system/systemd-networkd.service.requires/emulab-udev-settle-networkd.service \
        /etc/systemd/system/systemd-networkd.socket.requires/emulab-udev-settle-networkd.service \
        /etc/systemd/system/systemd-networkd.service.requires/emulab-udev-settle-networkd.service
    cat <<EOF >/etc/systemd/system/testbed-pre-static-control-network.service
[Unit]
Description=Testbed Static Control Network Services
After=network.target network-online.target local-fs.target
Wants=network.target
Before=testbed.service
Before=pubsubd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$OURDIR/testbed-pre-static-control-network.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
WantedBy=testbed.service
WantedBy=pubsubd.service
EOF
    cat <<EOF >$OURDIR/testbed-pre-static-control-network.sh
#!/bin/sh

#
# These are just the things we cannot do via hook from systemd-networkd,
# that were previously done in /etc/network/interfaces via "up" hook.
#
echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
EOF
    chmod 755 $OURDIR/testbed-pre-static-control-network.sh
    systemctl daemon-reload
    systemctl enable testbed-pre-static-control-network.service
    cat <<'EOF' >/etc/systemd/system/openvswitch-post-control-network.service
[Unit]
Description=Testbed OpenVswitch Static Control Network Flows
After=network.target network-online.target local-fs.target openvswitch-switch.service
Wants=network.target openvswitch-switch.service
Before=testbed.service
Before=pubsubd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for line in `cat /etc/neutron/ovs-default-flows/br-ex`; do ovs-ofctl add-flow br-ex $line ; done'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
WantedBy=testbed.service
WantedBy=pubsubd.service
EOF
    systemctl daemon-reload
    systemctl enable openvswitch-post-control-network.service
    cat <<EOF >/etc/systemd/network/${EXTERNAL_NETWORK_BRIDGE}.network
[Match]
Name=${EXTERNAL_NETWORK_BRIDGE}

[Network]
Description=OpenStack External Network Bridge
DHCP=no
Address=$ctlip/$ctlprefix
Gateway=$ctlgw
DNS=$DNSSERVER
Domains=$OURDOMAIN
IPForward=yes
EOF
    cat <<EOF >/etc/systemd/network/${EXTERNAL_NETWORK_INTERFACE}.network
[Match]
Name=${EXTERNAL_NETWORK_INTERFACE}

[Network]
Description=OpenStack External Network Bridge Physical Interface
DHCP=no
EOF
fi

ifconfig ${EXTERNAL_NETWORK_INTERFACE} 0 up
ifconfig ${EXTERNAL_NETWORK_BRIDGE} $ctlip netmask $ctlnetmask up
route add default gw $ctlgw

grep -q systemd-resolved /etc/resolv.conf
if [ $? -eq 0 ]; then
    resolvectl dns ${EXTERNAL_NETWORK_BRIDGE} $DNSSERVER
fi

service_restart openvswitch-switch

# Also restart slothd so it listens on the new control iface.
echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
/usr/local/etc/emulab/rc/rc.slothd stop
pkill slothd
sleep 1
/usr/local/etc/emulab/rc/rc.slothd start

#
# Add the management network config if necessary (if not, it's already a VPN)
#
if [ ! -z "$MGMTLAN" ]; then
    if [ $DISTRIB_MAJOR -lt 18 ]; then
	cat <<EOF >> /etc/network/interfaces

auto ${MGMT_NETWORK_INTERFACE}
iface ${MGMT_NETWORK_INTERFACE} inet static
    address $MGMTIP
    netmask $MGMTNETMASK
    up mkdir -p /var/run/emulab
    up echo "${MGMT_NETWORK_INTERFACE} $MGMTIP $MGMTMAC" > /var/run/emulab/interface-done-$MGMTMAC
EOF
    else
	cat <<EOF >/etc/systemd/network/${MGMT_NETWORK_INTERFACE}.network
[Match]
Name=${MGMT_NETWORK_INTERFACE}

[Network]
Description=OpenStack Management Network
DHCP=no
Address=$MGMTIP/$MGMTPREFIX
IPForward=yes
EOF
	cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
echo "${MGMT_NETWORK_INTERFACE} $MGMTIP $MGMTMAC" > /var/run/emulab/interface-done-$MGMTMAC
EOF
    fi
    if [ -n "$MGMTVLANDEV" ]; then
	if [ $DISTRIB_MAJOR -lt 18 ]; then
	    cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${MGMTVLANDEV}
EOF
	else
	    cat <<EOF >/etc/systemd/network/${MGMT_NETWORK_INTERFACE}.netdev
[NetDev]
Name=${MGMT_NETWORK_INTERFACE}
Kind=vlan

[VLAN]
Id=$MGMTVLANTAG
EOF
	    if [ ! -e /etc/systemd/network/${MGMTVLANDEV}.network ]; then
		cat <<EOF >/etc/systemd/network/${MGMTVLANDEV}.network
[Match]
Name=${MGMTVLANDEV}

[Network]
DHCP=no
VLAN=${MGMT_NETWORK_INTERFACE}
EOF
	    else
		cat <<EOF >>/etc/systemd/network/${MGMTVLANDEV}.network
VLAN=${MGMT_NETWORK_INTERFACE}
EOF
	    fi
	fi
    fi
fi

#
# Make sure we have the integration bridge
#
ovs-vsctl add-br ${INTEGRATION_NETWORK_BRIDGE}

#
# (Maybe) Setup the flat data networks
#
for lan in $DATAFLATLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    ovs-vsctl add-br ${DATABRIDGE}

    ovs-vsctl add-port ${DATABRIDGE} ${DATADEV}
    ifconfig ${DATADEV} 0 up
    if [ $DISTRIB_MAJOR -lt 18 ]; then
	cat <<EOF >> /etc/network/interfaces

auto ${DATABRIDGE}
iface ${DATABRIDGE} inet static
    address $DATAIP
    netmask $DATANETMASK
    up mkdir -p /var/run/emulab
    up echo "${DATABRIDGE} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC

auto ${DATADEV}
iface ${DATADEV} inet static
    address 0.0.0.0
EOF
	if [ -n "$DATAVLANDEV" ]; then
	    cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${DATAVLANDEV}
EOF
	fi
    else
	cat <<EOF >/etc/systemd/network/${DATABRIDGE}.network
[Match]
Name=${DATABRIDGE}

[Network]
Description=OpenStack Data Flat Lan $DATABRIDGE Network
DHCP=no
Address=$DATAIP/$DATAPREFIX
IPForward=yes
EOF
	cat <<EOF >/etc/systemd/network/${DATADEV}.network
[Match]
Name=${DATADEV}

[Network]
Description=OpenStack Data Flat Lan $DATABRIDGE Network Physical Interface
DHCP=no
EOF
	cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
echo "${DATABRIDGE} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC
EOF
	if [ -n "$DATAVLANDEV" ]; then
	    cat <<EOF >/etc/systemd/network/${DATADEV}.netdev
[NetDev]
Name=${DATADEV}
Kind=vlan

[VLAN]
Id=$DATAVLANTAG
EOF
	    if [ ! -e /etc/systemd/network/${DATAVLANDEV}.network ]; then
		cat <<EOF >/etc/systemd/network/${DATAVLANDEV}.network
[Match]
Name=${DATAVLANDEV}

[Network]
DHCP=no
VLAN=${DATADEV}
EOF
	    else
		cat <<EOF >/etc/systemd/network/${DATAVLANDEV}.network
VLAN=${DATADEV}
EOF
	    fi
	fi
    fi

    ifconfig ${DATABRIDGE} $DATAIP netmask $DATANETMASK up
    # XXX!
    #route add -net 10.0.0.0/8 dev ${DATA_NETWORK_BRIDGE}
done

#
# (Maybe) Setup the VLAN data networks.
# Note, these are for the case where we're giving openstack the chance
# to manage these networks... so we delete the emulab-created vlan devices,
# create an openvswitch switch for the vlan device, and just add the physical
# device as a port.  Simple.
#
for lan in $DATAVLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    ifconfig $DATADEV down
    vconfig rem $DATADEV

    # If the bridge exists, we've already done it (we might have multiplexed
    # (trunked) more than one vlan across this physical device).
    ovs-vsctl br-exists ${DATABRIDGE}
    if [ $? -ne 0 ]; then
	ovs-vsctl add-br ${DATABRIDGE}
	ovs-vsctl add-port ${DATABRIDGE} ${DATAVLANDEV}
    fi

    grep "^auto ${DATAVLANDEV}$" /etc/network/interfaces
    if [ ! $? -eq 0 ]; then
	if [ $DISTRIB_MAJOR -lt 18 ]; then
	    cat <<EOF >> /etc/network/interfaces
auto ${DATAVLANDEV}
iface ${DATAVLANDEV} inet static
    #address 0.0.0.0
    up mkdir -p /var/run/emulab
    # Just touch it, don't put iface/inet/mac into it; the vlans atop this
    # device are being used natively by openstack.  So just let Emulab setup
    # to not setup any of these vlans.
    up touch /var/run/emulab/interface-done-$DATAPMAC
EOF
	else
	    cat <<EOF >/etc/systemd/network/${DATAVLANDEV}.network
[Match]
Name=${DATAVLANDEV}

[Network]
UseDHCP=no
EOF
	    cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
# Just touch it, don't put iface/inet/mac into it; the vlans atop this
# device are being used natively by openstack.  So just let Emulab setup
# to not setup any of these vlans.
touch /var/run/emulab/interface-done-$DATAPMAC
EOF
	fi
    fi
done

#else
#    ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#
#    cat <<EOF >> /etc/network/interfaces
#
#auto ${DATA_NETWORK_INTERFACE}
#iface ${DATA_NETWORK_INTERFACE} inet static
#    address $DATAIP
#    netmask $DATANETMASK
#EOF
#    if [ -n "$DATAVLANDEV" ]; then
#	cat <<EOF >> /etc/network/interfaces
#    vlan-raw-device ${DATAVLANDEV}
#EOF
#    fi
#fi

#
# Set the hostname for later after reboot!
#
(echo $NFQDN | tr '[:upper:]' '[:lower:]') > /etc/hostname

service_restart openvswitch-switch

ip route flush cache

# Just wait a bit
#sleep 8

# Also re-run linkdelay setup; it got blown away.  However, it should be
# properly restored by rc.linkdelaysetup on future boots.
if [ -e /var/emulab/boot/rc.linkdelay ]; then
    echo "Restoring link shaping..."
    /var/emulab/boot/rc.linkdelay
fi

# Some services (neutron-ovs-cleanup) might lookup the hostname prior to
# network being up.  We have to handle this here once at startup; then
# again later in the rc.hostnames hook below.
echo $ctlip $NFQDN >> /tmp/hosts.tmp
cat /etc/hosts >> /tmp/hosts.tmp
mv /tmp/hosts.tmp /etc/hosts

grep -q DYNRUNDIR /etc/emulab/paths.sh
if [ $? -eq 0 ]; then
    echo "*** Hooking Emulab rc.hostnames boot script..."
    mkdir -p $OURDIR/bin
    touch $OURDIR/bin/rc.hostnames-openstack
    chmod 755 $OURDIR/bin/rc.hostnames-openstack
    cat <<EOF >$OURDIR/bin/rc.hostnames-openstack
#!/bin/sh

cp -p $OURDIR/mgmt-hosts /var/run/emulab/hosts.head

# Some services (neutron-ovs-cleanup) might lookup the hostname prior to
# network being up.
echo $ctlip $NFQDN >> /var/run/emulab/hosts.head
cp -p /var/run/emulab/hosts.head /var/run/emulab/hosts.tail

exit 0
EOF

    RCMDIR=/usr/local/etc/emulab/run/rcmanifest.d
    if [ -d /usr/libexec/emulab ]; then
	RCMDIR=/etc/emulab/run/rcmanifest.d
    fi
    mkdir -p $RCMDIR
    touch $RCMDIR/0.openstack-rcmanifest
    cat <<EOF >> $RCMDIR/0.openstack-rcmanifest
HOOK SERVICE=rc.hostnames ENV=boot WHENCE=every OP=boot POINT=pre FATAL=0 FILE=$OURDIR/bin/rc.hostnames-openstack ARGV="" 
EOF
else
    echo "*** Nullifying Emulab rc.hostnames and rc.ifconfig services!"
    mv /usr/local/etc/emulab/rc/rc.hostnames /usr/local/etc/emulab/rc/rc.hostnames.NO
    mv /usr/local/etc/emulab/rc/rc.ifconfig /usr/local/etc/emulab/rc/rc.ifconfig.NO
fi

if [ ! ${HAVE_SYSTEMD} -eq 0 ] ; then
    # Maybe this is helpful too
    update-rc.d networking remove
    update-rc.d networking defaults
    # This seems to block systemd from doing its job...
    systemctl disable ifup-wait-emulab-cnet.service
    systemctl mask ifup-wait-emulab-cnet.service
    systemctl stop ifup-wait-emulab-cnet.service
    #
    # XXX: fixup a systemd/openvswitch bug
    # https://bugs.launchpad.net/ubuntu/+source/openvswitch/+bug/1448254
    #
    #
    # Also, if our init is systemd, fixup the openvswitch service to
    # come up and go down before remote-fs.target .  Somehow,
    # openvswitch-switch always goes down way, way before the rest of
    # the network is brought down.  remote-fs.target seems to be one of
    # the last services to be killed before the network target is
    # brought down, and if there's an NFS mount, NFS might require
    # communication with the remote server to umount the mount.  This
    # affects us because there are Emulab/Cloudlab NFS mounts over the
    # control net device, and we bridge the control net device into the
    # br-ex openvswitch bridge.  To complete the story, once the
    # openvswitch-switch daemon goes down, you have about 30 seconds
    # before the bridge starts acting really flaky... it appears to go
    # down and quit forwarding traffic for awhile, then will pop back to
    # life periodically for 10-second chunks.  So, we hackily "fix" this
    # by making the openswitch-nonetwork service dependent on
    # remote-fs.target ... and since that target is one of the last to
    # go down before the real network is brought down, this seems to
    # work.  Ugh!  So to fix that, we also add the remote-fs.target
    # Before dependency to the "patch" listed in the above bug report.
    #
    cat <<EOF >/lib/systemd/system/openvswitch-nonetwork.service
    [Unit]
Description=Open vSwitch Internal Unit
PartOf=openvswitch-switch.service
DefaultDependencies=no
Wants=network-pre.target openvswitch-switch.service
Before=network-pre.target remote-fs.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/default/openvswitch-switch
ExecStart=/usr/share/openvswitch/scripts/ovs-ctl start \
          --system-id=random $OPTIONS
ExecStop=/usr/share/openvswitch/scripts/ovs-ctl stop
EOF

    systemctl enable openvswitch-switch
    systemctl daemon-reload
fi

#
# Install a basic ARP reply filter that prevents us from sending ARP replies on
# the control net for anything we're not allowed to use (i.e., we can reply for
# ourselves, and any public addresses we're allowed to use).  Really, we only
# need the public address part on the network manager, but may as well let
# any node reply as any public address we're allowed to use).
#

# Cheat and use our IPADDR/NETMASK instead of NETWORK/NETMASK below...
OURNET=`ip addr show br-ex | sed -n -e 's/.*inet \([0-9\.\/]*\) .*/\1/p'`
# Grab the port that corresponds to our
OURPORT=`ovs-ofctl show br-ex | sed -n -e "s/[ \t]*\([0-9]*\)(${EXTERNAL_NETWORK_INTERFACE}.*\$/\1/p"`

#
# Ok, make the anti-ARP spoofing rules live, and also place them in the right
# place to be picked up by our neutron openvswitch agent so that when it
# remove_all_flows() it also installs our "system" defaults.
#
mkdir -p /etc/neutron/ovs-default-flows
FF=/etc/neutron/ovs-default-flows/br-ex
touch ${FF}

#
# Huge hack.  Somewhere in Mitaka, something starts removing the first
# flow rule from the table (and that is the rule allowing our control
# net iface ARP replies to go out!).  So, put a simple rule at the head
# of the line that simply allows ARP replies from the local control net
# default gateway to arrive on our control net iface.  This rule is of
# course eclipsed by the "Allow any inbound ARP replies on the control
# network" rule below -- thus it is safe to allow this arbitrary process
# to delete.
#
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${ctlgw},in_port=${OURPORT},actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${ctlip},actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

# Somewhere in Stein, the internal openvswitch vlan tagging changed, so
# that even though vlan tags are applied in br-int for packets coming
# from br-ex, it is now br-ex's job to strip in the reverse direction.
# So for > Stein, just add strip_vlan for these ARP reply rules.  We
# only want to have them apply on traffic coming from br-int, but it's
# not obvious how to force a particular internal vlan assignment.  The
# only thing we could do is scrape the one assigned by openswitch-agent
# by looking at its db, or at the br-int flow rules.  But for now we
# don't have to care; any public ARP replies will need tags stripped
# since we don't support control net (br-ex) vlans right now.
pubactions="NORMAL"
if [ $OSVERSION -ge $OSSTEIN ] ; then
    pubactions="strip_vlan,NORMAL"
fi
for addr in $PUBLICADDRS ; do
    FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${addr},actions=${pubactions}"
    ovs-ofctl add-flow br-ex "$FLOW"
    echo "$FLOW" >> $FF
done
# Allow any inbound ARP replies on the control network.
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},in_port=${OURPORT},actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

# Drop any other control network addr ARP replies on the br-ex switch.
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=${OURNET},actions=drop"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

# Also, drop Emulab vnode control network addr ARP replies on br-ex!
FLOW="dl_type=0x0806,nw_proto=0x2,arp_spa=172.16.0.0/12,actions=drop"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

#
# A final hack.  These days (i.e. Pike), the neutron-openvswitch-agent
# is very aggressive to delete the default NORMAL flow on the br-ex
# bridge.  This causes problems for testbed.service on reboot, because
# connectivity effectively flaps as the NORMAL flow gets deleted and
# added.  So, we make a default NORMAL flow with our cookie, so it
# effectively won't be deleted.  Once the agent has initialized, its
# cookie will replace ours for this priority=0,actions=NORMAL flow, but
# that is fine.
#
FLOW="priority=0,actions=NORMAL"
ovs-ofctl add-flow br-ex "$FLOW"
echo "$FLOW" >> $FF

logtend "ovs-node"

exit 0
