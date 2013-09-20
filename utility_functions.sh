RDO_BASE="http://rdo.fedorapeople.org"
CIRROS="https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img"

AUTHORIZED_KEYS_FILE=$HOME/.ssh/authorized_keys
PRIVATE_KEY_FILE=$HOME/.ssh/id_rsa
PUBLIC_KEY_FILE=${PRIVATE_KEY_FILE}.pub

# A minimal CentOS install may not have these.
function install_requirements() {
    yum install -y wget dbus
}

# If dbus isn't running the compute service will fail to start.
function start_dbus() {
	service messagebus start
}

# Packstack seems to have a hard time getting things set up
# on its own, so the following functions set ssh access for
# root to root@localhost and check that it works.
function generate_ssh_key() {
    if ! [ -f $PRIVATE_KEY_FILE ]; then
        ssh-keygen -t rsa -b 2047 -f $PRIVATE_KEY_FILE -N ''
    fi
}

function configure_authorized_keys() {
    if ! grep -q -f $PUBLIC_KEY_FILE $AUTHORIZED_KEYS_FILE; then
        cat $PUBLIC_KEY_FILE >> $AUTHORIZED_KEYS_FILE
	chmod 600 $AUTHORIZED_KEYS_FILE
    fi
}

function test_ssh_connection() {
    if ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes localhost true; then
        die "ssh connection to localhost failed."
    fi
}

function configure_ssh_keys() {
    generate_ssh_key
    configure_authorized_keys
    test_ssh_connection
}

function install_rdo_release() {
    local release="$1"

    yum install -y ${RDO_BASE}/openstack-${release}/rdo-release-${release}.rpm
    if rpm -q openstack-packstack > /dev/null; then
	yum update -y openstack-*
    else
	yum install -y openstack-packstack
    fi
}

function get_packstack_answers() {
    ls packstack-answers*txt ~/packstack-answers*txt 2>/dev/null | cut -d ' ' -f 1
}

function set_packstack_value() {
    local answerfile="$1"
    local config_key="$2"
    local config_val="$3"

    if grep -q "^${config_key}=" "$answerfile"; then
	echo Updating ${config_key}=${config_val} >&2
	sed -i "/^${config_key}=/ s/=.*/=${config_val}/" "$answerfile"
    else
	echo Adding ${config_key}=${config_val} >&2
	echo "${config_key}=${config_val}" >> "$answerfile"
    fi
}

function merge_local_config() {
    local answerfile=$1

    [ -f "packstack-config.post" ] || return

    while read line; do
	local name=${line%=*}
	local value=${line#*=}
	set_packstack_value $answerfile $name $value
    done < packstack-config.post
}

function generate_packstack_answers () {
    local answerfile="packstack-answers-$(date +%Y%m%d).txt"

    if rpm -q openstack-packstack | grep -q 2013.1; then
	neutron=QUANTUM
    else
	neutron=NEUTRON
    fi

    packstack --gen-answer-file $answerfile
    set_packstack_value $answerfile CONFIG_${neutron}_INSTALL n
    merge_local_config $answerfile
    echo $answerfile
}

function do_packstack() {
    local answers=$(get_packstack_answers)

    if ! [ "$answers" -a -f "$answers" ]; then
	generate_packstack_answers
        answers=$(get_packstack_answers)
    fi

    if ! [ "$answers" -a -f "$answers" ]; then
	die Failed to find or generate an answers file.
    fi

    packstack --answer-file "$answers"
}

function create_instance() {
    local name="$1"

    if [ ! -f ~/cirros.img ]; then
	wget -O ~/cirros.img "$CIRROS"
    fi

    if ! glance image-show cirros >/dev/null 2>&1; then
	glance image-create --name cirros --is-public True \
	    --disk-format qcow2 --container-format bare < ~/cirros.img
    fi

    nova delete "$name"
    nova boot --poll --image cirros --flavor 1 "$name"
}

function die() {
    reason="$*"
    echo "ERROR: $reason" >&2
    exit 1
}

function try_instance() {
    cmd="$1"
    for i in $(seq 0 20); do
	($cmd) >/dev/null 2>&1 && return 0
	sleep 1
    done
    return 1
}    

function check_instance_console() {
    local name="$1"
    nova console-log "$name" | grep cubswin
}

function test_instance() {
    local name="$1"
    ipaddr=$(nova show "$name" | grep network | cut -d '|' -f 3)
    try_instance "ping -c1 $ipaddr" || {
	die 'Failed to ping test instance at $ipaddr'
    }
    try_instance "check_instance_console $name" || {
	die 'Failed to connect to test instance console'
    }
    echo "*** Test instance $name looks OK ***"
}

function destroy_instance() {
    local name="$1"
    nova delete "$name"
}

function service_control() {
    action="$1"
    for service in $(chkconfig --list | grep 'openstack.*3:on' | awk '{print $1}'); do
	service $service "$action"
    done
}
