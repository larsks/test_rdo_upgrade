function upgrade_dbs() {
    for service in nova glance cinder keystone; do
	if ${service}-manage --help 2>&1 | grep -q upgrade; then
	    ${service}-manage upgrade
	elif ${service}-manage --help 2>&1 | grep -q db_sync; then
	    ${service}-manage db_sync
	else
	    ${service}-manage db sync
	fi
    done
}

function upgrade_add_sheepdog() {
    yum install -y sheepdog
}

function upgrade_packstack_config() {
    local answers=$(get_packstack_answers)

    # Convert QUANTUM -> NEUTRON configs
    sed -ri 's/CONFIG_QUANTUM/CONFIG_NEUTRON/' $answers

    # Add config elements that havana packstack wants to see
    # These are defaults that might not be right
    cat >> $answers <<EOF
CONFIG_MYSQL_INSTALL=y
CONFIG_CEILOMETER_INSTALL=n
CONFIG_HEAT_INSTALL=n
CONFIG_CINDER_BACKEND=lvm
CONFIG_NOVA_NETWORK_MANAGER=nova.network.manager.FlatDHCPManager
CONFIG_HEAT_CLOUDWATCH_INSTALL=n
CONFIG_HEAT_CFN_INSTALL=n
EOF
    }

function upgrade_other_computes() {
    local answers=$(get_packstack_answers)
    local computes=$(grep 'COMPUTE_HOSTS' $answers | cut -d= -f2 | sed 's/,/ /')
    local me=$(grep 'NOVA_API_HOST' $answers | cut -d= -f2)
    local pkgs="openstack-nova-compute python-oslo-config"
    for compute in $computes; do
	if [ "$compute" = "$me" ]; then
	    echo Skipping myself
	else
	    echo HACK: Upgrading packages on $compute
	    ssh -oStrictHostKeyChecking=no $compute \
		    "yum upgrade -y && service openstack-nova-compute restart"
	fi
    done
}
