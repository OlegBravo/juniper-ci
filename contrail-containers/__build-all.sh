#!/bin/bash -e

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  echo "INFO: Preparing Ubuntu host to build containers  $(date)"
  sudo apt-get -y update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  echo "INFO: Preparing CentOS host to build containers  $(date)"
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin
  sudo yum install -y epel-release
  sudo yum install -y mc git wget ntp iptables iproute
  sudo systemctl enable ntpd.service
  sudo systemctl start ntpd.service
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

./contrail-build-poc/build.sh