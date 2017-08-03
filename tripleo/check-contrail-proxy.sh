#!/bin/bash -e

DEBUG=${DEBUG:-1}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_addr=$1
shift
ssh_opts=$@

MAX_FAIL=${MAX_FAIL:-30}
USE_VENV=${USE_VENV:-'true'}
SSH_CMD=${SSH_CMD:-'ssh'}

cos_dir='/home/stack/check-openstack'
ssh -T $ssh_opts $ssh_addr "mkdir -p $cos_dir/tripleo"
scp $ssh_opts $my_dir/check-openstack.sh $ssh_addr:$cos_dir/tripleo/
scp $ssh_opts -r $my_dir/../common $ssh_addr:$cos_dir/
ssh -T $ssh_opts $ssh_addr "chown -R stack:stack $cos_dir"
run_opts="SSH_CMD=$SSH_CMD USE_VENV=$USE_VENV MAX_FAIL=$MAX_FAIL DEBUG=$DEBUG OPENSTACK_VERSION=$OPENSTACK_VERSION USE_DPDK=$DPDK"
ssh -T $ssh_opts $ssh_addr "sudo -u stack $run_opts $cos_dir/tripleo/check-openstack.sh"
