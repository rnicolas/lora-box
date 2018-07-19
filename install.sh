#!/bin/bash

# Stop on the first sign of trouble
set -e

if [ $UID != 0 ]; then
    echo "ERROR: Operation not permitted. Forgot sudo?"
    exit 1
fi

if [[ $1 != "" ]]; then VERSION=$1; fi

echo "LoRa Box installer"
echo
# Update the gateway installer to the correct branch
echo "Updating installer files..."
OLD_HEAD=$(git rev-parse HEAD)
git fetch
git checkout
git pull
NEW_HEAD=$(git rev-parse HEAD)
if [[ $OLD_HEAD != $NEW_HEAD ]]; then
    echo "New installer found. Restarting process..."
    exec "./install.sh" "$VERSION"
fi
# Disabling Blank Screen and PowerDown when Pi is not active.
#echo "Disabling blank screen after 30 minutes of inactivity"
#pushd /etc/kbd/
#sed -i -e 's/BLANK_TIME=30/BLANK_TIME=0/g' ./config
#echo "Disabling Automatic Power Off after 30 minutes of inactivity"
#sed -i -e 's/POWERDOWN_TIME=30/POWERDOWN_TIME=0/g' ./config
#popd
# Check dependencies
echo "Updating OS..."
apt-get update
apt-get -y upgrade
echo "OS Updated"

loraGw() {
	echo "Activating SPI port on Raspberry PI"

	pushd /boot
	sed -i -e 's/#dtparam=spi=on/dtparam=spi=on/g' ./config.txt
	popd

	# Request gateway configuration data
	# There are two ways to do it, manually specify everything
	# or rely on the gateway EUI and retrieve settings files from remote (recommended)
	echo "Gateway configuration:"

	# Try to get gateway ID from MAC address
	# First try eth0, if that does not exist, try wlan0 (for RPi Zero)
	GATEWAY_EUI_NIC="eth0"
	if [[ `grep "$GATEWAY_EUI_NIC" /proc/net/dev` == "" ]]; then
	    GATEWAY_EUI_NIC="wlan0"
	fi

	if [[ `grep "$GATEWAY_EUI_NIC" /proc/net/dev` == "" ]]; then
	    echo "ERROR: No network interface found. Cannot set gateway ID."
	    exit 1
	fi

	GATEWAY_EUI=$(ip link show $GATEWAY_EUI_NIC | awk '/ether/ {print $2}' | awk -F\: '{print $1$2$3"FFFE"$4$5$6}')
	GATEWAY_EUI=${GATEWAY_EUI^^} # toupper

	echo "Detected EUI $GATEWAY_EUI from $GATEWAY_EUI_NIC"

	# Setting personal configuration of LoRaWAN Gateway
	printf "       Host name [lora-box]:"
	read NEW_HOSTNAME
	if [[ $NEW_HOSTNAME == "" ]]; then NEW_HOSTNAME="lora-box"; fi

	printf "       Descriptive name [RPi-iC880A]:"
	read GATEWAY_NAME
	if [[ $GATEWAY_NAME == "" ]]; then GATEWAY_NAME="RPi-iC880A"; fi

	printf "       Contact email: "
	read GATEWAY_EMAIL

	printf "       Latitude [0]: "
	read GATEWAY_LAT
	if [[ $GATEWAY_LAT == "" ]]; then GATEWAY_LAT=0; fi

	printf "       Longitude [0]: "
	read GATEWAY_LON
	if [[ $GATEWAY_LON == "" ]]; then GATEWAY_LON=0; fi

	printf "       Altitude [0]: "
	read GATEWAY_ALT
	if [[ $GATEWAY_ALT == "" ]]; then GATEWAY_ALT=0; fi

	# Change hostname if needed
	CURRENT_HOSTNAME=$(hostname)

	if [[ $NEW_HOSTNAME != $CURRENT_HOSTNAME ]]; then
	    echo "Updating hostname to '$NEW_HOSTNAME'..."
	    hostname $NEW_HOSTNAME
	    echo $NEW_HOSTNAME > /etc/hostname
	    sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/" /etc/hosts
	fi

	# Install LoRaWAN packet forwarder repositories
	INSTALL_DIR="/opt/lora-box"
	if [ ! -d "$INSTALL_DIR" ]; then mkdir $INSTALL_DIR; fi
	pushd $INSTALL_DIR

	# Build LoRa gateway app
	if [ ! -d lora_gateway ]; then
	    git clone https://github.com/Lora-net/lora_gateway.git
	    pushd lora_gateway
	else
	    pushd lora_gateway
	    git reset --hard
	    git pull
	fi
	make

	popd

	# Build packet forwarder
	if [ ! -d packet_forwarder ]; then
	    git clone https://github.com/Lora-net/packet_forwarder.git
	    pushd packet_forwarder
	else
	    pushd packet_forwarder
	    git pull
	    git reset --hard
	fi
	make

	popd

	# Symlink packet forwarder
	if [ ! -d bin ]; then mkdir bin; fi
	if [ -f ./bin/lora_pkt_fwd ]; then rm ./bin/lora_pkt_fwd; fi
	ln -s $INSTALL_DIR/packet_forwarder/lora_pkt_fwd/lora_pkt_fwd ./bin/lora_pkt_fwd
	cp -f ./packet_forwarder/lora_pkt_fwd/global_conf.json ./bin/global_conf.json

	LOCAL_CONFIG_FILE=$INSTALL_DIR/bin/local_conf.json

	# Remove old config file
	if [ -e $LOCAL_CONFIG_FILE ]; then
		rm $LOCAL_CONFIG_FILE
	fi

	printf "       Server Address ['localhost']:"
	read NEW_SERVER
	if [[ $NEW_SERVER == "" ]]; then NEW_SERVER="localhost"; fi

	echo -e "{\n\t\"gateway_conf\": {\n\t\t\"gateway_ID\": \"$GATEWAY_EUI\",\n\t\t\"server_address\": \"$NEW_SERVER\",\n\t\t\"serv_port_up\": 1700,\n\t\t\"serv_port_down\": 1700,\n\t\t\"ref_latitude\": $GATEWAY_LAT,\n\t\t\"ref_longitude\": $GATEWAY_LON,\n\t\t\"ref_altitude\": $GATEWAY_ALT,\n\t\t\"contact_email\": \"$GATEWAY_EMAIL\",\n\t\t\"description\": \"$GATEWAY_NAME\" \n\t}\n}" >$LOCAL_CONFIG_FILE

	popd

	echo "Gateway EUI is: $GATEWAY_EUI"
	echo "The hostname is: $NEW_HOSTNAME"
	echo "The Gateway is pointing to: $NEW_SERVER"
	echo
	echo "Installation completed."

	# Start packet forwarder as a service
	cp ./start.sh $INSTALL_DIR/bin/
	pushd $INSTALL_DIR/bin/
	chmod +x start.sh
	popd
	cp ./lora-box.service /etc/systemd/system/
	systemctl enable lora-box.service
}

loraServer() {
	apt-get install -y apt-transport-https
	apt-get update
	apt-get upgrade

	echo "Installing dependencies"
	apt-get install -y mosquitto mosquitto-clients redis-server redis-tools postgresql-common postgresql-client postgresql

	# Create a password file for your mosquitto users, starting with a “root” user.
	# The “-c” parameter creates the new password file. The command will prompt for
	# a new password for the user.
	mosquitto_passwd -c /etc/mosquitto/passwd loraroot

	# Add users for the various MQTT protocol users
	printf "Configuring MQTT (mosquitto) service:"
	printf "       Insert Lora Gateway Password for MQTT authentication ['loragwpasswd']:"
	read LORA_GW_PASSWD
	if [[ $LORA_GW_PASSWD == "" ]]; then
		LORA_GW_PASSWD='loragwpasswd'
	fi
	mosquitto_passwd -b /etc/mosquitto/passwd loragw $LORA_GW_PASSWD

	printf "       Insert Lora Server Password for MQTT authentication ['loraserverpasswd']:"
	read LORA_SERVER_PASSWD
	if [[ $LORA_SERVER_PASSWD == "" ]]; then
		LORA_SERVER_PASSWD='loraserverpasswd'
	fi
	mosquitto_passwd -b /etc/mosquitto/passwd loraserver $LORA_SERVER_PASSWD

	printf "       Insert Lora Application Server Password for MQTT authentication ['loraappserverpasswd']:"
	read LORA_APP_SERVER_PASSWD
	if [[ $LORA_APP_SERVER_PASSWD == "" ]]; then
		LORA_APP_SERVER_PASSWD='loraappserverpasswd'
	fi
	mosquitto_passwd -b /etc/mosquitto/passwd loraappserver $LORA_APP_SERVER_PASSWD

	# Secure the password file
	chmod 600 /etc/mosquitto/passwd

	pushd /etc/mosquitto/conf.d/
	if [ ! -f local.conf ]; then
		echo "allow_anonymous false" > local.conf
		echo "password_file /etc/mosquitto/passwd" > local.conf
	fi
	echo "MQTT (mosquitto) configuration is done."
	systemctl restart mosquitto

	printf "Configuring Database (PostgreSQL):"
	#psql script to create user and database.
	printf "       Type here the password for postgresql user loraserver_ns ['dbpassword']"
	read DB_PASSWORD_NS
	if [[ $DB_PASSWORD_NS == "" ]]; then
		DB_PASSWORD_NS='dbpassword'
	fi

	sudo -u postgres psql -c "create role loraserver_ns with login password '$DB_PASSWORD_NS';"
	sudo -u postgres psql -c "create database loraserver_ns with owner loraserver_ns;"

	#psql script to create user and database.
	echo "       Type here the password for postgresql user loraserver_as ['dbpassword']"
	read DB_PASSWORD_AS
	if [[ $DB_PASSWORD_AS == "" ]]; then
		DB_PASSWORD_AS='dbpassword'
	fi

	sudo -u postgres psql -c "create role loraserver_as with login password '$DB_PASSWORD_AS';"
	sudo -u postgres psql -c "create database loraserver_as with owner loraserver_as;"
	sudo -u postgres psql -d loraserver_as -c "create extension pg_trgm;"
	echo "Database (PostgreSQL) configuration is done"
	echo "Installing LoRa Gateway Bridge"

	pushd /etc/apt/sources.list.d/
	#check if loraserver repository is added into sources
	if [ ! -f loraserver.list ]; then
		apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1CE2AFD36DBCCA00
		echo "deb https://artifacts.loraserver.io/packages/1.x/deb stable main" | tee loraserver.list
	fi
	popd

	apt-get update

	echo "Installing LoRa-Gateway-Bridge"

	apt-get install -y lora-gateway-bridge

	echo "Installing LoRaWAN Server"

	apt-get install -y loraserver

	echo "Installing LoRa Application Server"

	apt-get install -y lora-app-server

	pushd /etc/lora-gateway-bridge/
	sed -i "s/username=\"\"/username=\"loragw\"/" lora-gateway-bridge.toml
	sed -i "s/password=\"\"/password=\"$LORA_GW_PASSWD\"/" lora-gateway-bridge.toml
	popd

	pushd /etc/lora-app-server
	sed -i "s/username=\"\"/username=\"loraappserver\"/" lora-app-server.toml
	sed -i "s/password=\"\"/password=\"$LORA_APP_SERVER_PASSWD\"/" lora-app-server.toml
	sed -i "s/dsn=\"postgres:\/\/localhost\/loraserver_as?sslmode=disable\"/dsn=\"postgres:\/\/loraserver_as:$DB_PASSWORD_AS@localhost\/loraserver_as?sslmode=disable/\"" lora-app-server.toml
	JWT_SECRET=$(openssl rand -base64 33)
	sed -i "s/jwt_secret=\"\"/jwt_secret=\"$JWT_SECRET\"/" lora-app-server.toml
	popd

	pushd /etc/loraserver
	sed -i "s/username=\"\"/username=\"loraserver\"/" loraserver.toml
	sed -i "s/password=\"\"/password=\"$LORA_SERVER_PASSWD\"/" loraserver.toml
	#POSTGRES-DSN
	sed -i "s/dsn=\"postgres:\/\/localhost\/loraserver_ns?sslmode=disable\"/dsn=\"postgres:\/\/loraserver_ns:$DB_PASSWORD_NS@localhost\/loraserver_ns?sslmode=disable/\"" loraserver.toml
	popd

	echo "In order to get the system working the files '/etc/default/lora-gateway-bridge', '/etc/default/loraserver' and '/etc/default/lora-app-server' must be updated with the correct parameters"

	echo "The system will reboot in 30 seconds..."
	sleep 30
	shutdown -r now
}

switch ($case) {
	case 'lightLoraBox':
		loraGw
		break;
	case 'LoraBox':
		loraGw
		loraServer
		break;
	case 'loraServer':
		loraServer
		break;
}
