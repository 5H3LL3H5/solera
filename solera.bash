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
		install_package "$package"
		initial_setup
	fi

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

#                                                          INSTALL_DB_PACKAGE()
#
# installs database package
# source: https://www.howtoforge.com/tutorial/install-mongodb-on-ubuntu-16.04
###############################################################################
install_package()
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
	log_action_begin_msg "Installing $package via apt"
	sudo apt-get install -y "$package" &> /dev/null
	log_action_end_msg $?

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
		})
	" &> /dev/null
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

#                                                           REMOVE_CONF_FILES()
#
# removes mongodb configuration files
# only for teesting purposes
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
# only for teesting purposes
###############################################################################
remove_installation()
{
	local -r service="mongod"
	local -r package="mongodb-org"
	local -r mongodb_version="4.2"

	log_action_begin_msg "Stopping system service $service"
	sudo systemctl stop "$service";
	log_action_end_msg $?

	if package_installed "$package";
	then
		log_action_begin_msg "Deinstalling $package"
		sudo apt -y purge "$package" &> /dev/null
		log_action_end_msg $?
	fi

	remove_conf_files
}


#                                                                          BODY
###############################################################################

# code in here only gets executed if script is run directly on the cmdline
if [ "${BASH_SOURCE[0]}" == "$0" ];
then

	. /lib/lsb/init-functions

	remove_installation

	# pass whole parameter list to main
	if main "$@"; then
		echo "SCRIPT SUCCESSFUL FINISHED"
	else
		echo "ERROR RUNNING SCRIPT"
	fi

fi