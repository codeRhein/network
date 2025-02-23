#!/bin/bash -x

set -euo pipefail

TEST_SOURCE_DIR="/network-role"
C8S_CONTAINER_IMAGE="quay.io/linux-system-roles/c8s-network-role"
C7_CONTAINER_IMAGE="quay.io/linux-system-roles/c7-network-role"
C9S_CONTAINER_IMAGE="quay.io/linux-system-roles/c9s-network-role"
PODMAN_OPTS="--systemd=true --privileged"

# FIXME: test_wireless has been removed because is not supported on CI
# container EL7. We need to add this back for EL8 or greater.
EXCLUDE_TESTS='
-e tests/tests_802_1x_updated_nm.yml
-e tests/tests_auto_gateway_initscripts.yml
-e tests/tests_bond_deprecated_initscripts.yml
-e tests/tests_bond_deprecated_nm.yml
-e tests/tests_bond_initscripts.yml
-e tests/tests_default_initscripts.yml
-e tests/tests_default_nm.yml
-e tests/tests_default.yml
-e tests/tests_ethernet_initscripts.yml
-e tests/tests_ethernet_nm.yml
-e tests/tests_eth_pci_address_match_nm.yml
-e tests/tests_ethtool_coalesce_initscripts.yml
-e tests/tests_ethtool_features_initscripts.yml
-e tests/tests_ethtool_ring_initscripts.yml
-e tests/tests_helpers_and_asserts.yml
-e tests/tests_integration_pytest.yml
-e tests/tests_ipv6_dns_search_nm.yml
-e tests/tests_ipv6_initscripts.yml
-e tests/tests_provider_nm.yml
-e tests/tests_reapply_nm.yml
-e tests/tests_regression_nm.yml
-e tests/tests_route_table_nm.yml
-e tests/tests_states_initscripts.yml
-e tests/tests_states_nm.yml
-e tests/tests_team_nm.yml
-e tests/tests_team_plugin_installation_nm.yml
-e tests/tests_unit.yml
-e tests/tests_vlan_mtu_initscripts.yml
-e tests/tests_wireless_nm.yml
-e tests/tests_wireless_plugin_installation_nm.yml
-e tests/tests_wireless_wpa3_owe_nm.yml
-e tests/tests_wireless_wpa3_sae_nm.yml
'

read -r -d '' TEST_FILES << EOF || :
$(find tests/tests_*.yml | egrep -v ${EXCLUDE_TESTS})
EOF

EXEC_PATH=$(dirname "$(realpath "$0")")
PROJECT_PATH=$(dirname "$(realpath "$EXEC_PATH../")")

# Default
OS_TYPE=c8s

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        --os)
            OS_TYPE=$2
            shift # past argument
            shift # past value
            ;;
        *)    # unknown option
            echo "Unknown option, please try $1 --os c8s"
            exit 1
            ;;
    esac
done

case $OS_TYPE in
    "c8s")
        CONTAINER_IMAGE=$C8S_CONTAINER_IMAGE
        ;;
    "c7")
        CONTAINER_IMAGE=$C7_CONTAINER_IMAGE
        ;;
    "c9s")
        CONTAINER_IMAGE=$C9S_CONTAINER_IMAGE
        ;;
    *)
        echo "Unsupported OS type $OS_TYPE"
        exit 1
        ;;
esac

# shellcheck disable=SC2086
CONTAINER_ID=$(podman run -d $PODMAN_OPTS \
    -v "$PROJECT_PATH":$TEST_SOURCE_DIR $CONTAINER_IMAGE)

if [ -z "$CONTAINER_ID" ];then
    echo "Failed to start container"
    exit 1
fi

function clean_up {
    podman rm -f "$CONTAINER_ID" || true
}

if [ -z "${DEBUG:-}" ];then
    trap clean_up ERR EXIT
fi

# Ensure we are testing the latest packages and ignore upgrade failure
sudo podman exec -i "$CONTAINER_ID" /bin/bash -c  'dnf upgrade -y' || true

podman exec -i "$CONTAINER_ID" \
    /bin/bash -c  \
        'while ! systemctl is-active dbus; do sleep 1; done'

podman exec -i "$CONTAINER_ID" \
    /bin/bash -c  'sysctl -w net.ipv6.conf.all.disable_ipv6=0'

sudo podman exec -i "$CONTAINER_ID" \
        /bin/bash -c  \
                'systemctl start systemd-udevd;
        while ! systemctl is-active systemd-udevd; do sleep 1; done'


podman exec -i "$CONTAINER_ID" \
    /bin/bash -c  \
        'systemctl restart NetworkManager;
         while ! systemctl is-active NetworkManager; do sleep 1; done'

podman exec -i "$CONTAINER_ID" \
    /bin/bash -c  \
        'systemctl restart sshd;
         while ! systemctl is-active sshd; do sleep 1; done'

podman exec -i "$CONTAINER_ID" \
    /bin/bash -c  \
        'cat /dev/zero | ssh-keygen -q -N "";
         cp -v /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys'

for test_file in $TEST_FILES; do
    podman exec -i "$CONTAINER_ID" \
        /bin/bash -c  \
            "cd $TEST_SOURCE_DIR;
             env ANSIBLE_HOST_KEY_CHECKING=False \
                 ansible-playbook -i localhost, \
                 $test_file"
done

if [ -n "${DEBUG:-}" ];then
    podman exec -it "$CONTAINER_ID" bash
    clean_up
fi
