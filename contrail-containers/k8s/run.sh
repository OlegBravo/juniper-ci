#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

# definition for job deployment
source $my_dir/${HOST}-defs
source $my_dir/../common/functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '2,3'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

for dest in $nodes_ips ; do
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@${dest}:./
done
$my_dir/setup-nodes.sh

run_env=''
if [[ "$REGISTRY" == 'build' ]]; then
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@$build_ip:./
  $SCP "$my_dir/../__build-containers.sh" ${SSH_USER}@$build_ip:build-containers.sh
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR"
  ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD ${SSH_USER}@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  run_env="CONTRAIL_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=$CONTRAIL_VERSION REGISTRY_INSECURE=1"
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  run_env="CONTRAIL_REGISTRY=opencontrailnightly CONTRAIL_CONTAINER_TAG=latest REGISTRY_INSECURE=0"
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

$SCP "$my_dir/__run-gate.sh" ${SSH_USER}@$master_ip:run-gate.sh
timeout -s 9 60m $SSH_CMD ${SSH_USER}@$master_ip "$run_env LINUX_DISTR=$LINUX_DISTR AGENT_MODE=$AGENT_MODE ./run-gate.sh"

trap - ERR
save_logs '2,3'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
