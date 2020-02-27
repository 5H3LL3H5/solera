#!/usr/bin/env bash
#
# Copyright (C) 2020, Christian Stenzel, <christianstenzel@linux.com>
#
# Purpose:
#
#
# Editor settings:
# tabstops=4	/ set ts=4
# shiftwidth=4	/ set sw=4


#                                                                        MAIN()
#
# main control function
###############################################################################
main()
{
	local -r package="mongodb-org"

	if ! package_installed "$package";
	then
		install_mongodb_package "$package"
		initial_setup
	fi

	create_www_folders
	clone_git_reps
	install_javascript_dependencies
	configure_frontend
	configure_backend
	sleep 3
	start_backend
	sleep 3
	start_frontend
	generate_selfsigned_cert
	setup_nginx

	return 0 # exit success
}


#                                                           PACKAGE_INSTALLED()
#
# verifies package installation
#
# @param[in]	package		package name
# @param[out]	0			package installed
# @param[out]	1			invalid function usage
# @param[out]	2			empty or invalid package name
# @param[out]	3			package not installed
###############################################################################
package_installed()
{
	local -r package="$1"

	# check if one parameter was passed
	if (( $# != 1 ));
	then
		log_failure_msg "Invalid function call"
		return 1
	fi

	# check if package specifier empty or only contains spaces
	if [[ -z "${package// }" ]];
	then
		log_failure_msg "Invalid package specifier"
		return 2                # invalid package name
	fi

	if ! dpkg --status "$package" &> /dev/null;
	then
		return 3                # package not installed
	fi

	return 0                    # package already installed
}


#                                                           CHECK_CONFIG_FILE()
#
# checks config file syntax
###############################################################################
check_config_file()
{
	return 0	      # exit success
}


#                                                         INSTALL_APT_PACKAGE()
#
# installs apt package
#
# @param[in]	package		package name
###############################################################################
install_apt_package()
{
	local -r package="$1"
	local -i status

	package_installed "$package"
	status=$?

	if (( status == 3 ));
	then
		log_action_begin_msg "Installing $package via apt"
		sudo apt-get -y install "$package" &> /dev/null
		log_end_msg $?
	fi
}


#                                                         INSTALL_NPM_PACKAGE()
#
# installs npm package
#
# @param[in]	package		package name
###############################################################################
install_npm_package()
{
	local -r package="$1"

	if ! npm list -g "$package" &> /dev/null;
	then
		log_action_begin_msg "Installing $package via npm"
		sudo npm install -g "$package" &> /dev/null
		log_end_msg $?
	fi
}


#                                                      INSTALL_MOGODB_PACKAGE()
#
# installs database package
# source: https://www.howtoforge.com/tutorial/install-mongodb-on-ubuntu-16.04
###############################################################################
install_mongodb_package()
{
	local -r mongodb_version="4.2"
	local -r keyserver="hkp://keyserver.ubuntu.com"
	local -r -i port=80

	local -r lsb_release_name=$(lsb_release -sc)
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r service="mongod"
	local -r mongo_service_fn="$service.service"
	local -r mongo_service_dir="/lib/systemd/system/"

	local -r package="$1"

	local keyid="INVALID"

	# remove artefacts from previous installations
	remove_conf_files

	# handle different ubuntu releases
	case "$lsb_release_name" in
		"xenial")
			keyid="E52529D4"
			;;
		"bionic")
			keyid="4B7C549A058F8B6B"
			;;
		*)
			log_failure_msg "Invalid OS"
			exit 1
	esac

	# start installation

	# add keyserver
	log_action_begin_msg "Adding keyserver"
	sudo apt-key adv --keyserver "$keyserver:$port" --recv "$keyid" \
		&> /dev/null
	log_action_end_msg $?

	# create MongoDB list file in /etc/apt/sources.list.d
	log_action_begin_msg "Create MongoDB source list file"
	echo "deb http://repo.mongodb.org/apt/ubuntu \
		$lsb_release_name/mongodb-org/$mongodb_version multiverse" |\
		sudo tee "$apt_source_dir/$apt_source_fn" &> /dev/null
	log_action_end_msg $?

	# update rep and install mongodb
	log_action_begin_msg "Updating apt database"
	sudo apt-get update &> /dev/null
	log_action_end_msg $?
	install_apt_package "$package"

	# create mongo db system service
	cat <<-EOF | \
	sudo tee -a /lib/systemd/system/"$mongo_service_fn" > /dev/null
		[Unit]
		Description=High-performance, schema-free document-oriented database
		After=network.target
		Documentation=https://docs.mongodb.org/manual

		[Service]
		User=mongodb
		Group=mongodb
		ExecStart=/usr/bin/mongod --quiet --config /etc/mongod.conf

		[Install]
		WantedBy=multi-user.target
	EOF

	# update systemd service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &> /dev/null
	log_action_end_msg $?

	# start MongoDB and add it as a service to be started at boot time
	log_action_begin_msg "Starting $service"
	sudo systemctl start "$service" &> /dev/null
	log_action_end_msg $?
	log_action_begin_msg "Enabling $service"
	sudo systemctl enable "$service" &> /dev/null
	log_action_end_msg $?

	# wait five secs for service startup
	sleep 5

	log_action_begin_msg "Check status of $service"
	if ! sudo systemctl status "$service" &> /dev/null;
	then
		log_action_end_msg 1
		return 1
	else
		log_action_end_msg 0
		return 0
	fi
}


#                                                            INITIAL_DB_SETUP()
#
# inital database setup
###############################################################################
initial_setup()
{
	local -r username="admin"
	local -r password="admin123"
	local -r db="admin"
	local -r service="mongod"

	log_action_begin_msg "Deleting MongoDB user $username"
	mongo --quiet --eval "
	db=db.getSiblingDB(\"$db\");
	db.dropUser(\"$username\")
	" &> /dev/null
	log_action_end_msg $?

	log_action_begin_msg "Adding inital user $username to database"
	mongo --quiet --eval "
		db=db.getSiblingDB(\"$db\");
		db.createUser({
		user:\"$username\", \
		pwd:\"$password\", \
		roles:[{role:'root', db:'$db'}]
	})" &> /dev/null
	log_action_end_msg $?

	log_action_begin_msg "Adapting $service configuration"
	pattern="^ExecStart=.*$"
	repl="ExecStart=/usr/bin/mongod --quiet --auth --config /etc/mongod.conf"
	sudo sed -i \
		"s/$pattern/${repl//\//\\/}/" \
		/lib/systemd/system/mongod.service
	log_action_end_msg $?

	# reloading service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &> /dev/null
	log_action_end_msg $?

	log_action_begin_msg "Restarting $service"
	sudo service "$service" restart
	log_action_end_msg $?

	return 0	      # exit success
}


#                                                       CREATE_REMOTE_FOLDERS()
###############################################################################
create_www_folders()
{
	local -r basedir="/var/www/sagesutra"
	local -r backenddir="backend"
	local -r frontenddir="frontend"

	[[ ! -d "$basedir" ]] && sudo mkdir -p "$basedir"

	if [[ ! -d "$basedir/$backenddir" ]];
	then
		sudo mkdir -p "$basedir/$backenddir"
	else
		# what to do here ? -> test if content is gitdir and has correct origin
		# then git pull
		:
	fi

	if [[ ! -d "$basedir/$frontenddir" ]];
	then
		sudo mkdir -p "$basedir/$frontenddir"
	else
		# what to do here ? -> test if content is gitdir and has correct origin
		# then git pull
		:
	fi
}


#                                                              CLONE_GIT_REPS()
###############################################################################
clone_git_reps()
{
	local -r basedir="/var/www/sagesutra"
	local -r backenddir="backend"
	local -r backenduri="https://github.com/Anas-MI/cbdbene-backend.git"
	local -r frontenddir="frontend"
	local -r frontenduri="https://github.com/shubhamAyodhyavasi/cbdbenev2.git"

	log_action_begin_msg "Cloning backend"
	if [[ -d "$basedir/$backenddir" ]];
	then
		sudo git -C "$basedir/$backenddir" clone "$backenduri" &> /dev/null
	fi
	log_action_end_msg $?

	log_action_begin_msg "Cloning frontend"
	if [[ -d "$basedir/$frontenddir" ]];
	then
		sudo git -C "$basedir/$frontenddir" clone "$frontenduri" &> /dev/null
	fi
	log_action_end_msg $?
}


#                                             INSTALL_JAVASCRIPT_DEPENDENCIES()
###############################################################################
install_javascript_dependencies()
{
	local -r basedir="/var/www/sagesutra"
	local -r backenddir="backend/cbdbene-backend"
	local -r frontenddir="frontend/cbdbenev2"

	local -r curwd="$(pwd)"

	install_apt_package npm
	install_npm_package pm2

	cd "$basedir/$frontenddir" || return 1
	log_action_begin_msg "Install js deps"
	sudo npm install --unsafe-perm &> /dev/null
	log_action_end_msg $?
	cd "$curwd" || return 1

	cd "$basedir/$backenddir" || return 1
	log_action_begin_msg "Install js deps"
	sudo npm install --unsafe-perm &> /dev/null
	log_action_end_msg $?
	cd "$curwd" || return 1

	return 0
}


#                                                          CONFIGURE_FRONTEND()
###############################################################################
configure_frontend()
{
	adapt_frontend_port
	adapt_frontend_url
}


#                                                         ADAPT_FRONTEND_PORT()
###############################################################################
adapt_frontend_port()
{
	local -i port=3007
	local -r pattern1='"dev": "next dev"'
	local -r pattern2='"start": "next start"'
	local -r basedir="/var/www/sagesutra"
	local -r frontenddir="frontend/cbdbenev2"
	local -r conffile="$basedir/$frontenddir/package.json"

	log_action_begin_msg "Adapting frontend port"
	sudo sed -i "s/$pattern1/${pattern1:0:-1} -p $port\"/" "$conffile"
	sudo sed -i "s/$pattern2/${pattern2:0:-1} -p $port\"/" "$conffile"
	log_action_end_msg $?
}


#                                                          ADAPT_FRONTEND_URL()
###############################################################################
adapt_frontend_url()
{
	local -r basedir="/var/www/sagesutra"
	local -r frontenddir="frontend/cbdbenev2"
	local -r conffile="$basedir/$frontenddir/constants/projectSettings.js"

	local -r pattern1="export const baseUrl"
	local -r pattern2="admin.cbdbene.com"
	local -r url="admin.sagesutra.com"

	log_action_begin_msg "Adapting frontend url"
	sudo sed -i "s/^\($pattern1.*= \).*$/\1\"https:\/\/$url\";/" "$conffile"
	sudo sed -i "s/$pattern2/$url/" "$conffile"
	log_action_end_msg $?
}

#                                                           CONFIGURE_BACKEND()
###############################################################################
configure_backend()
{
	local -r basedir="/var/www/sagesutra"
	local -r backenddir="backend/cbdbene-backend"
	local -r envfile=".env"
	local -r serverurl="https://sagesutra.com"
	local -r clienturl="https://sagesutra.com"
	local -r dbname="admin"
	local -r dbusername="admin"
	local -r dbpassword="admin123"
	local -r dbhostname="localhost"
	local -r -i dbport=27017
	local -r clientid="936223668088-mg6le6oiabj4qrpj82c28dpj8ctf648d.apps.googleusercontent.com"
	local -r clientsecret="gWiuvxeJ4mbddARAdIYsnltc"
	local -r keyid="AKIAJMUJXEIE42GYPGRA"
	local -r region="us-west-2"
	local -r accesskey="n45vnKDW053nk+129lnbyEQkZkCVkN8m20Qs6Js2"
	local -r bucket="new-maxxbio"
	local -r -i serverport="5003"

	cat <<-EOF | \
	sudo tee -a "$basedir/$backenddir/$envfile" &> /dev/null
		PORT=$serverport
		CLIENT_URL="$serverurl"
		serverurl="$clienturl"
		MONGOLAB_URI="mongodb://$dbusername:$dbpassword@$dbhostname:$dbport/$dbname?retryWrites=true&w=majority"
		GOOGLE_CLIENT_ID=$clientid
		GOOGLE_CLIENT_SECRET=$clientsecret
		ACCESSKEYID=$keyid
		REGION=$region
		SECRETACCESSKEY=$accesskey
		BUCKET=$bucket
	EOF
}


#                                                               START_BACKEND()
###############################################################################
start_backend()
{
	local -r basedir="/var/www/sagesutra"
	local -r backenddir="backend/cbdbene-backend"
	local -r curwd="$(pwd)"
	local -r instance_name="sagesutra-backend"

	cd "$basedir/$backenddir" || return 1
	log_action_begin_msg "Starting nodejs backend"
	pm2 start "npm start" -n "$instance_name" &> /dev/null
	log_action_end_msg $?
	cd "$curwd" || return 1
}

#                                                              START_FRONTEND()
###############################################################################
start_frontend()
{
	local -r basedir="/var/www/sagesutra"
	local -r frontenddir="frontend/cbdbenev2"
	local -r curwd="$(pwd)"
	local -r instance_name="sagesutra-frontend"

	cd "$basedir/$frontenddir" || return 1
	log_action_begin_msg "Building frontend dependencies"
	sudo npm run build &> /dev/null
	log_action_end_msg $?
	log_action_begin_msg "Starting nodejs frontend"
	pm2 start "npm start" -n "$instance_name" &> /dev/null
	log_action_end_msg $?
	cd "$curwd" || return 1
}


#                                                    GENERATE_SELFSIGNED_CERT()
###############################################################################
generate_selfsigned_cert()
{
	local -r -i valid_days=365
	local -r country="US"
	local -r province="Denial"
	local -r city="Springfield"
	local -r organization="Department"
	local -r cn="www.sagesutra.com"

	install_apt_package openssl

	log_action_begin_msg "Creating self signed certificate"
	sudo openssl req \
		-new \
		-newkey rsa:4096 \
		-days $valid_days \
		-nodes \
		-x509 \
		-subj "/C=$country/ST=$province/L=$city/O=$organization/CN=$cn" \
		-keyout "$cn".key \
		-out "$cn".cert \
	&> /dev/null
	log_action_end_msg $?

	return 0
}

#                                                                 SETUP_NGINX()
###############################################################################
setup_nginx()
{
	local -r conffile="/etc/nginx/sites-enabled/default"

	install_apt_package nginx-light

	[[ -f "$conffile" ]] && sudo rm "$conffile"

	cat << EOF | sudo tee -a "$conffile" > /dev/null
	server {
		listen 80 default_server;
		listen [::]:80 default_server;
		root /var/www/html;
		server_name _;
		location / {
			# First attempt to serve request as file, then
			# as directory, then fall back to displaying a 404.
			try_files \$uri \$uri/ =404;
		}
	}

	server {
	}
EOF

	sudo sed -i "s/^\t//" "$conffile"


	return 0
}


#                                                           REMOVE_CONF_FILES()
#
# removes mongodb configuration files
# only for testing purposes
###############################################################################
remove_conf_files()
{
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r mongo_service_fn="mongod.service"
	local -r mongo_service_dir="/lib/systemd/system/"

	if [[ -f "$apt_source_dir/$apt_source_fn" ]];
	then
		log_action_begin_msg "Removing source list file $apt_source_fn"
		sudo rm "$apt_source_dir/$apt_source_fn"
		log_action_end_msg $?
	fi

	if [[ -f "$mongo_service_dir/$mongo_service_fn" ]];
	then
		log_action_begin_msg "Removing system service file $mongo_service_fn"
		sudo rm "$mongo_service_dir/$mongo_service_fn"
		log_action_end_msg $?
	fi
}


#                                                         REMOVE_INSTALLATION()
#
# removes mongodb installation
# only for testing purposes
###############################################################################
remove_installation()
{
	local -r service="mongod"
	local -r package="mongodb-org"
	local -r mongodb_version="4.2"
	local -r basedir="/var/www/sagesutra"

	log_action_begin_msg "Stopping system service $service"
	sudo systemctl stop "$service";
	log_action_end_msg 0

	log_action_begin_msg "Removing pm2 processes"
	pm2 delete all &> /dev/null
	log_action_end_msg 0

	rm -rf ./*.cert &> /dev/null
	rm -rf ./*.key &> /dev/null

	if package_installed "$package";
	then
		log_action_begin_msg "Deinstalling $package"
		sudo apt -y purge "$package" &> /dev/null
		log_action_end_msg $?
	fi

	sudo rm -rf "$basedir"

	remove_conf_files
}


#                                                                          BODY
###############################################################################

# code in here only gets executed if script is run directly on the cmdline
if [ "${BASH_SOURCE[0]}" == "$0" ];
then

	# source lsb init function file for advanced log functions
	if [[ ! -f /lib/lsb/init-functions ]];
	then
		>&2 echo "Error sourcing /lib/lsb/init-functions"
		exit 1
	fi
	. /lib/lsb/init-functions

	# ONLY IN DEV
	remove_installation

	# pass whole parameter list to main
	if ! main "$@";
	then
		log_begin_msg "Script error"
		log_end_msg 1
		exit 1
	fi

fi
