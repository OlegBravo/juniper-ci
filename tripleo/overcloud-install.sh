#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NUM=${NUM:-0}

# common setting from create_env.sh
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

SSH_VIRT_TYPE=${VIRT_TYPE:-'virsh'}
BASE_ADDR=${BASE_ADDR:-172}
MEMORY=${MEMORY:-8291}
SWAP=${SWAP:-0}
SSH_USER=${SSH_USER:-'stack'}
CPU_COUNT=${CPU_COUNT:-2}
DISK_SIZE=${DISK_SIZE:-30}

# su - stack
cd ~

if [[ "$(whoami)" != "stack" ]] ; then
  echo "This script must be run under the 'stack' user"
  exit 1
fi

((addr=BASE_ADDR+NUM*10))
virt_host_ip="192.168.${addr}.1"
if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
  virsh_opts="-c qemu+ssh://${SSH_USER}@${virt_host_ip}/system"
  list_vm_cmd="virsh $virsh_opts list --all"
else
  ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  ssh_addr="${SSH_USER}@${virt_host_ip}"
  list_vm_cmd="ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage list vms"
fi

CONT_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-cont- | wc -l)
COMP_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-comp- | wc -l)
CONTROLLER_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-ctrlcont- | wc -l)
ANALYTICS_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-analytics- | wc -l)
ANALYTICSDB_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-analyticsdb- | wc -l)
((OCM_COUNT=CONT_COUNT+COMP_COUNT+CONTROLLER_COUNT+ANALYTICS_COUNT+ANALYTICSDB_COUNT))

# collect MAC addresses of overcloud machines
function get_macs() {
  type=$1
  count=$2
  truncate -s 0 /tmp/nodes-$type.txt
  for (( i=1; i<=count; i++ )) ; do
    if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
      virsh $virsh_opts domiflist rd-overcloud-$NUM-$type-$i | awk '$3 ~ "prov" {print $5};'
    else
      ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage showvminfo rd-overcloud-$NUM-$type-$i | awk '/NIC 1/ {print $4}' | cut -d ',' -f 1 | sed 's/\(..\)/\1:/g' | sed 's/:$//'
    fi
  done > /tmp/nodes-$type.txt
  echo "macs for '$type':"
  cat /tmp/nodes-$type.txt
}

get_macs cont $CONT_COUNT
get_macs comp $COMP_COUNT
get_macs controller $CONTROLLER_COUNT
get_macs analytics $ANALYTICS_COUNT
get_macs analyticsdb $ANALYTICSDB_COUNT

id_rsa=$(awk 1 ORS='\\n' ~/.ssh/id_rsa)
# create overcloud machines definition
cat << EOF > ~/instackenv.json
{
  "ssh-user": "$SSH_USER",
  "ssh-key": "$id_rsa",
  "host-ip": "$virt_host_ip",
  "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
  "arch": "x86_64",
  "nodes": [
EOF

function define_machine() {
  caps=$1
  mac=$2
  cat << EOF >> ~/instackenv.json
    {
      "pm_addr": "$virt_host_ip",
      "pm_user": "$SSH_USER",
      "pm_password": "$id_rsa",
      "pm_type": "pxe_ssh",
      "ssh_virt_type": "$SSH_VIRT_TYPE",
      "vbox_use_headless": "True",
      "mac": [
        "$mac"
      ],
      "cpu": "$CPU_COUNT",
      "memory": "$MEMORY",
      "disk": "$DISK_SIZE",
      "arch": "x86_64",
      "capabilities": "$caps"
    },
EOF
}

for (( i=1; i<=CONT_COUNT; i++ )) ; do
  mac=$(sed -n ${i}p /tmp/nodes-cont.txt)
  define_machine "profile:controller,boot_option:local" $mac
done
for (( i=1; i<=COMP_COUNT; i++ )) ; do
  mac=$(sed -n ${i}p /tmp/nodes-comp.txt)
  define_machine "profile:compute,boot_option:local" $mac
done
for (( i=1; i<=CONTROLLER_COUNT; i++ )) ; do
  mac=$(sed -n ${i}p /tmp/nodes-controller.txt)
  define_machine "profile:contrail-controller,boot_option:local" $mac
done
for (( i=1; i<=ANALYTICS_COUNT; i++ )) ; do
  mac=$(sed -n ${i}p /tmp/nodes-analytics.txt)
  define_machine "profile:contrail-analytics,boot_option:local" $mac
done
for (( i=1; i<=ANALYTICSDB_COUNT; i++ )) ; do
  mac=$(sed -n ${i}p /tmp/nodes-analyticsdb.txt)
  define_machine "profile:contrail-analyticsdb,boot_option:local" $mac
done

# remove last comma
head -n -1 ~/instackenv.json > ~/instackenv.json.tmp
mv ~/instackenv.json.tmp ~/instackenv.json
cat << EOF >> ~/instackenv.json
    }
  ]
}
EOF

# check this json (it's optional)
if [[ "$DEPLOY" != 1 ]] ; then
  curl --silent -O https://raw.githubusercontent.com/rthallisey/clapper/master/instackenv-validator.py
  python instackenv-validator.py -f instackenv.json
fi

source ~/stackrc

# re-define flavors
for id in `openstack flavor list -f value -c ID` ; do openstack flavor delete $id ; done

swap_opts=''
if [[ $SWAP != 0 ]] ; then
  swap_opts="--swap $SWAP"
fi
openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT baremetal
openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" baremetal

if [[ $CONT_COUNT > 0 ]] ; then
  openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT controller
  openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="controller" controller
fi

if [[ $COMP_COUNT > 0 ]] ; then
  openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT compute
  openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="compute" compute
fi

if [[ $CONTROLLER_COUNT > 0 ]] ; then
  openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT contrail-controller
  openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="contrail-controller" contrail-controller
fi

if  [[ $ANALYTICS_COUNT > 0 ]] ; then
  openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT contrail-analytics
  openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="contrail-analytics" contrail-analytics
fi

if [[ $ANALYTICSDB_COUNT > 0 ]] ; then
  openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT contrail-analyticsdb
openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="contrail-analyticsdb" contrail-analyticsdb
fi

openstack flavor list --long

# import overcloud configuration
openstack baremetal import --json ~/instackenv.json
openstack baremetal list
# and configure overcloud
openstack baremetal configure boot

# do introspection - ironic will collect some hardware information from overcloud machines
openstack baremetal introspection bulk start
# this is a recommended command to check and wait end of introspection. but previous command can wait itself.
#sudo journalctl -l -u openstack-ironic-discoverd -u openstack-ironic-discoverd-dnsmasq -u openstack-ironic-conductor -f


# prepare Contrail puppet modules
mkdir -p ~/usr/share/openstack-puppet/modules
git clone https://github.com/Juniper/contrail-tripleo-puppet -b stable/newton ~/usr/share/openstack-puppet/modules/tripleo
#TODO: replace personal repo with Juniper ones
git clone https://github.com/alexey-mr/puppet-contrail -b stable/newton ~/usr/share/openstack-puppet/modules/contrail
tar czvf puppet-modules.tgz usr/
upload-swift-artifacts -f puppet-modules.tgz

# prepare tripleo heat templates
cp -r /usr/share/openstack-tripleo-heat-templates/ ~/tripleo-heat-templates
git clone https://github.com/Juniper/contrail-tripleo-heat-templates -b stable/newton
cp -r contrail-tripleo-heat-templates/environments/contrail ~/tripleo-heat-templates/environments
cp -r contrail-tripleo-heat-templates/puppet/services/network/* ~/tripleo-heat-templates/puppet/services/network

#TODO: add yaml with concrete parameters

ha_opts=""
if (( CONT_COUNT > 1 )) ; then
  ha_opts="-e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml"
fi

if [[ "$DEPLOY" != '1' ]] ; then
  # deploy overcloud. if you do it manually then I recommend to do it in screen.
  echo "openstack overcloud deploy --templates tripleo-heat-templates/ \
    --roles-file tripleo-heat-templates/environments/contrail/roles_data_ci.yaml \
    -e tripleo-heat-templates/environments/contrail/contrail-services.yaml \
    -e tripleo-heat-templates/environments/contrail/contrail-net-single.yaml \
    --control-flavor control --control-scale $CONT_COUNT \
    --compute-flavor compute  --compute-scale $COMP_COUNT \
    --ntp-server pool.ntp.org $ha_opts"
  echo "Add '-e templates/firstboot/firstboot.yaml' if you use swap"
  exit
fi

# script will handle errors below
set +e

openstack overcloud deploy --templates tripleo-heat-templates/ \
  --roles-file tripleo-heat-templates/environments/contrail/roles_data_ci.yaml \
  -e tripleo-heat-templates/environments/contrail/contrail-services.yaml \
  -e tripleo-heat-templates/environments/contrail/contrail-net-single.yaml \
  --control-flavor control --control-scale $CONT_COUNT \
  --compute-flavor compute  --compute-scale $COMP_COUNT \
  --ntp-server pool.ntp.org $ha_opts


errors=$?

echo "INFO: collecting HEAT logs"

echo "INFO: Heat logs" > heat.log
heat stack-list -n >> heat.log
for id in `heat deployment-list | awk '/FAILED/{print $2}'` ; do
  echo "ERROR: Failed deployment $id" >> heat.log
  heat deployment-show $id | grep -vP "stdout|stderr" >> heat.log
  echo "ERROR: stdout" >> heat.log
  heat deployment-output-show $id deploy_stdout >> heat.log
  echo "ERROR: stderr" >> heat.log
  heat deployment-output-show $id deploy_stderr >> heat.log
  ((++errors))
done

for id in `heat resource-list -n 10 overcloud | awk '/FAILED/{print $12"+"$2}'` ; do
  sn="`echo $id | cut -d '+' -f 1`"
  rn="`echo $id | cut -d '+' -f 2`"
  echo "ERROR: Failed resource $sn  $rn" >> heat.log
  heat resource-show $sn $rn >> heat.log
  ((++errors))
done

for id in `heat stack-list | awk '/FAILED/{print $2}'` ; do
  echo "ERROR: Failed stack $id" >> heat.log
  heat stack-show $id >> heat.log
  ((++errors))
done

if (( errors > 0 )) ; then
  exit 1
fi