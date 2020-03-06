#!/usr/bin/env bash
# shellcheck disable=SC2024
#
# Copyright (C) 2020, Christian Stenzel, <christianstenzel@linux.com>
#
# Purpose:
#
#
# Editor settings:
# tabstops=4	/ set ts=4
# shiftwidth=4	/ set sw=4

declare fqdn="www.cstenzel.com"
declare sld=${fqdn#www.}			# sagesutra2.com
declare domainlabel=${sld%.*}		# sagesutra2

#                                                                        MAIN()
#
# main control function
###############################################################################
main()
{
	local -r package="mongodb-org"

	# ONLY IN DEV
	# remove_installation

	install_package_dependencies

	install_mongodb_package

	# delete any runnning pm2 domain related processes
	delete_pm2_process "$domainlabel-backend"
	delete_pm2_process "$domainlabel-frontend"

	clone_git_reps

	install_javascript_dependencies

	configure_backend

	configure_frontend
	build_frontend

	setup_nginx
	install_certbot

	# install certificates via letscert
	sudo certbot run \
		--non-interactive \
		--agree-tos \
		--register-unsafely-without-email \
		--nginx \
		--domain "${fqdn#www.}" \
		--domain "$fqdn" \
		--domain admin."${fqdn#www.}" &>> "$LOGFILE"

	start_backend
	start_frontend

	# install startup scripts
	pm2 save &>> "$LOGFILE"
	bash -c "$(pm2 startup | tail --lines 1)" &>> "$LOGFILE"

	return 0 # exit success
}


#                                                           CHECK_CONFIG_FILE()
#
# checks config file syntax
###############################################################################
check_config_file()
{
	return 0	      # exit success
}

#                                                INSTALL_PACKAGE_DEPENDENCIES()
#
# installs required packages
###############################################################################
install_package_dependencies()
{
	local -r nginx_flavour="light"
	local -r viaapt="git nginx-$nginx_flavour sed coreutils systemd
					 init-system-helpers openssl gnupg curl"
	local -r vianpm="pm2"

	local package

	log_action_begin_msg "Updating apt database"
	sudo apt-get update &>> "$LOGFILE"
	log_action_end_msg $?

	for package in $viaapt;
	do
		install_apt_package "$package"
	done

	if ! is_apt_package_installed nodejs;
	then
		# install instruction
		# https://github.com/nodesource/distributions/blob/master/README.md
		log_action_begin_msg "Installing nodejs"
		sudo --preserve-env \
			bash - < <(curl --silent --location \
				http://deb.nodesource.com/setup_13.x) &>> "$LOGFILE"
		install_apt_package nodejs
		log_action_end_msg 0
		# update to latest https://www.npmjs.com/get-npm
		log_action_begin_msg "Installing latest npm"
		sudo npm install npm@latest &>> "$LOGFILE"
		log_action_end_msg 0
	fi

	for package in $vianpm;
	do
		install_npm_package "$package"
	done
}


#                                                    IS_APT_PACKAGE_INSTALLED()
#
# verifies installation of apt package
#
# @param[in]	package		package name
# @param[out]	0			package installed
# @param[out]	1			invalid function usage
# @param[out]	2			empty or invalid package name
# @param[out]	3			package not installed
###############################################################################
is_apt_package_installed()
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

	if ! dpkg --status "$package" &>> "$LOGFILE";
	then
		return 3                # package not installed
	fi

	return 0                    # package already installed
}

#                                                    IS_NPM_PACKAGE_INSTALLED()
#
# verifies installation of npm package
#
# @param[in]	package		package name
# @param[out]	0			package installed
# @param[out]	1			invalid function usage
# @param[out]	2			empty or invalid package name
# @param[out]	3			package not installed
###############################################################################
is_npm_package_installed()
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

	if ! npm list --global "$package" &>> "$LOGFILE";
	then
		return 3                # package not installed
	fi

	return 0                    # package already installed
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

	if ! is_apt_package_installed "$package";
	then
		log_action_begin_msg "Installing $package via apt"
		sudo apt-get --assume-yes install "$package" &>> "$LOGFILE"
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

	if ! is_npm_package_installed "$package";
	then
		log_action_begin_msg "Installing $package via npm"
		sudo npm install --global "$package" &>> "$LOGFILE"
		log_end_msg $?
	fi
}


#                                                      INSTALL_MOGODB_PACKAGE()
#
# installs mongodb package
# see https://docs.mongodb.com/manual/tutorial/install-mongodb-on-ubuntu
###############################################################################
install_mongodb_package()
{
	local -r -i port=80
	local -r mongodb_version="4.2"
	local -r lsb_release_name=$(lsb_release --codename --short)
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r service="mongod"
	local -r mongo_service_fn="$service.service"
	local -r mongo_service_dir="/lib/systemd/system/"

	local -r package="mongodb-org"

	if is_apt_package_installed "$package";
	then
		return 1;
	fi

	# remove artefacts from previous installations
	remove_conf_files

	# create log and lib dir
	[[ ! -d /var/lib/mongodb ]] && \
		sudo mkdir --parents /var/lib/mongodb &>> "$LOGFILE" 

	[[ ! -d /var/log/mongodb ]] && \
		sudo mkdir --parents /var/log/mongodb &>> "$LOGFILE" 

	# import public key
	log_action_begin_msg "Import MongoDB public gpg key"
	sudo apt-key add - < <(curl --silent --location \
		https://www.mongodb.org/static/pgp/server-"$mongodb_version".asc) \
		&>> "$LOGFILE"
	log_action_end_msg $?

	# create MongoDB list file in /etc/apt/sources.list.d
	log_action_begin_msg "Create MongoDB source list file"
	echo "deb http://repo.mongodb.org/apt/ubuntu \
		$lsb_release_name/mongodb-org/$mongodb_version multiverse" |\
		sudo tee "$apt_source_dir/$apt_source_fn" &>> "$LOGFILE"
	log_action_end_msg $?

	# update rep and install mongodb
	log_action_begin_msg "Updating apt database"
	sudo apt-get update &>> "$LOGFILE"
	log_action_end_msg $?

	install_apt_package "$package"

	# pins current mongodb version
	echo "mongodb-org hold" | sudo dpkg --set-selections
	echo "mongodb-org-server hold" | sudo dpkg --set-selections
	echo "mongodb-org-shell hold" | sudo dpkg --set-selections
	echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
	echo "mongodb-org-tools hold" | sudo dpkg --set-selections

	# create mongo db system service
	cat <<-EOF | \
	sudo tee --append /lib/systemd/system/"$mongo_service_fn" >> "$LOGFILE"
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

	# change directory permissions if necessary
	[[ "$(stat --format '%U' /var/lib/mongodb/)" != "mongodb" ]] && \
			sudo chown --recursive mongodb:mongodb /var/lib/mongodb \
				&>> "$LOGFILE"

	[[ "$(stat --format '%U' /var/log/mongodb/)" != "mongodb" ]] && \
			sudo chown --recursive mongodb:mongodb /var/log/mongodb \
				&>> "$LOGFILE"

	# update systemd service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &>> "$LOGFILE"
	log_action_end_msg $?

	# start MongoDB and add it as a service to be started at boot time
	log_action_begin_msg "Starting $service"
	sudo systemctl start "$service" &>> "$LOGFILE"
	log_action_end_msg $?
	log_action_begin_msg "Enabling $service"
	sudo systemctl enable "$service" &>> "$LOGFILE"
	log_action_end_msg $?

	# wait five secs for service startup
	sleep 5

	log_action_begin_msg "Check status of $service"
	if ! sudo systemctl status "$service" &>> "$LOGFILE";
	then
		log_action_end_msg 1
		return 1
	else
		setup_mongo_database
		log_action_end_msg 0
		return 0
	fi
}


#                                                        SETUP_MONGO_DATABASE()
#
# inital database setup
###############################################################################
setup_mongo_database()
{
	local -r username="admin"
	local -r password="admin123"
	local -r db="admin"
	local -r service="mongod"

	log_action_begin_msg "Deleting MongoDB user $username"
	mongo --quiet --eval "
	db=db.getSiblingDB(\"$db\");
	db.dropUser(\"$username\")" &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Adding inital user $username to database"
	mongo --quiet --eval "
		db=db.getSiblingDB(\"$db\");
		db.createUser({
		user:\"$username\", \
		pwd:\"$password\", \
		roles:[{role:'root', db:'$db'}]})" &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Adapting $service configuration"
	pattern="^ExecStart=.*$"
	repl="ExecStart=/usr/bin/mongod --quiet --auth --config /etc/mongod.conf"
	sudo sed --in-place \
		"s/$pattern/${repl//\//\\/}/" \
		/lib/systemd/system/mongod.service
	log_action_end_msg $?

	# reloading service
	log_action_begin_msg "Reloading daemon configuration"
	sudo systemctl daemon-reload &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Restarting $service"
	sudo service "$service" restart &>> "$LOGFILE"
	log_action_end_msg $?

	return 0
}


#                                                              CLONE_GIT_REPS()
###############################################################################
clone_git_reps()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r backenduri="https://github.com/Anas-MI/cbdbene-backend.git"
	local -r frontenddir="frontend"
	local -r frontenduri="https://github.com/shubhamAyodhyavasi/cbdbenev2.git"

	if [[ ! -d "$basedir" ]];
	then
		sudo mkdir --parents "$basedir" &>> "$LOGFILE"
		sudo chown --recursive "$USER:$(id --group --name)" "$basedir" \
			&>> "$LOGFILE"
	fi

	if [[ ! -d "$basedir/$backenddir" ]];
	then
		log_action_begin_msg "Cloning backend"
		git -C "$basedir" clone "$backenduri" "$backenddir" &>> "$LOGFILE"
		log_action_end_msg $?
	else
		log_action_begin_msg "Pulling backend"
		git -C "$basedir/$backenddir" pull &>> "$LOGFILE"
		log_action_end_msg $?
	fi

	if [[ ! -d "$basedir/$frontenddir" ]];
	then
		log_action_begin_msg "Cloning frontend"
		git -C "$basedir" clone "$frontenduri" "$frontenddir" &>> "$LOGFILE"
		log_action_end_msg $?
	else
		log_action_begin_msg "Pulling frontend"
		git -C "$basedir/$frontenddir" pull &>> "$LOGFILE"
		log_action_end_msg $?
	fi
}


#                                             INSTALL_JAVASCRIPT_DEPENDENCIES()
###############################################################################
install_javascript_dependencies()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r frontenddir="frontend"
	local -r curwd="$(pwd)"

	log_action_begin_msg "Install backend dependencies"
	cd "$basedir/$backenddir" || return 1
	npm update &>> "$LOGFILE"
	log_action_end_msg $?
	cd "$curwd" || return 1

	log_action_begin_msg "Install frontend dependencies"
	cd "$basedir/$frontenddir" || return 1
	npm update &>> "$LOGFILE"
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
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend"
	local -r conffile="$basedir/$frontenddir/package.json"

	log_action_begin_msg "Adapting frontend port"
	sed --in-place "s/$pattern1/${pattern1:0:-1} -p $port\"/" "$conffile"
	sed --in-place "s/$pattern2/${pattern2:0:-1} -p $port\"/" "$conffile"
	log_action_end_msg $?
}


#                                                          ADAPT_FRONTEND_URL()
###############################################################################
adapt_frontend_url()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend"
	local -r conffile="$basedir/$frontenddir/constants/projectSettings.js"

	local -r pattern1="export const baseUrl"
	local -r pattern2="https:\/\/admin.cbdbene.com"
	local -r httpsurl="https:\/\/admin.$domainlabel.com"
	local -r httpurl="http:\/\/admin.$domainlabel.com"

	log_action_begin_msg "Adapting frontend url"
	sed --in-place "s/^\($pattern1.*= \).*$/\1\"$httpsurl\";/" "$conffile"
	sed --in-place "s/$pattern2/$httpurl/" "$conffile"
	log_action_end_msg $?
}


#                                                              BUILD_FRONTEND()
###############################################################################
build_frontend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend"

	local -r curwd="$(pwd)"
	local -r -i max_runs=10
	local -i successful_build=1

	log_action_begin_msg "Building frontend dependencies"

	cd "$basedir/$frontenddir" || return 1
	# in case insufficient ram repeat build til successful
	for (( i=1; i<=max_runs; i++));
	do
		if npm run build &>> "$LOGFILE";
		then
			successful_build=0
			break;
		fi
	done

	if (( successful_build != 0 ));
	then
		log_action_end_msg 1
		log_failure_msg "Unable to build frontend. Give up."
		exit 1
	fi

	log_action_end_msg 0

	cd "$curwd" || return 1
}


#                                                           CONFIGURE_BACKEND()
###############################################################################
configure_backend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r envfile=".env"
	local -r clienturl="https://$domainlabel.com"
	local -r serverurl="https://$domainlabel.com"
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
	local -r -i serverport=5003

	cat <<-EOF > "$basedir/$backenddir/$envfile"
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
	local -r basedir="/var/www/$domainlabel"
	local -r backenddir="backend"
	local -r curwd="$(pwd)"
	local -r instance_name="$domainlabel-backend"

	# delete running pm2 backend
	delete_pm2_process "$instance_name"

	cd "$basedir/$backenddir" || return 1
	log_action_begin_msg "Starting nodejs backend"
	pm2 start "npm start" --name "$instance_name" &>> "$LOGFILE"
	log_action_end_msg $?
	sleep 3
	cd "$curwd" || return 1
}

#                                                              START_FRONTEND()
###############################################################################
start_frontend()
{
	local -r basedir="/var/www/$domainlabel"
	local -r frontenddir="frontend"
	local -r curwd="$(pwd)"
	local -r instance_name="$domainlabel-frontend"

	# delete running pm2 frontend
	delete_pm2_process "$instance_name"

	cd "$basedir/$frontenddir" || return 1
	log_action_begin_msg "Starting nodejs frontend"
	pm2 start "npm start" --name "$instance_name" &>> "$LOGFILE"
	log_action_end_msg $?
	sleep 3
	cd "$curwd" || return 1
}

#                                                          DELETE_PM2_PROCESS()
###############################################################################
delete_pm2_process()
{
	local -r process="$1"

	! grep --quiet "$process" < <(pm2 ls) && return 1

	pm2 delete "$process" &>> "$LOGFILE"

	return $?
}


#                                                                 SETUP_NGINX()
###############################################################################
setup_nginx()
{
	local -r domain="$domainlabel.com"
	local -r conffile="/etc/nginx/sites-available/$domain"
	local -r symlink="/etc/nginx/sites-enabled/$domain"
	local -r nginx_flavour="light"
	local -r -i frontend_port=3007
	local -r -i backend_port=5003

	log_action_begin_msg "Configure and restart webserver"

	{
		[[ -e "$symlink" ]] && sudo rm "$symlink"
		[[ -f "$conffile" ]] && sudo rm "$conffile"

		cat << EOF | \
		sudo tee --append "$conffile"
		server {
			listen 80;
			server_name $domain www.$domain;
			location / {
				return 301 https://\$host\$request_uri;
			}
		}

		server {
			listen 443 ssl;
			listen [::]:443 ssl ;
			server_name $domain www.$domain;
			location / {
				proxy_pass http://localhost:$frontend_port;
				proxy_http_version 1.1;
				proxy_set_header Upgrade \$http_upgrade;
				proxy_set_header Connection 'upgrade';
				proxy_set_header Host \$host;
				proxy_cache_bypass \$http_upgrade;
			}
		}

		server {
			listen 80;
			server_name admin.$domain;
			location / {
				return 301 https://\$host\$request_uri;
			}
		}

		# Point backend domain name to port
		server {
			listen 443 ssl;
			index index.html index.htm index.nginx-debian.html;
			server_name admin.$domain;
			location / {
				proxy_pass http://localhost:$backend_port;
				proxy_http_version 1.1;
				proxy_set_header Upgrade \$http_upgrade;
				proxy_set_header Connection 'upgrade';
				proxy_set_header Host \$host;
				proxy_cache_bypass \$http_upgrade;
			}
		}
EOF

	sudo sed --in-place "s/^\t//" "$conffile"
	sudo ln --symbolic "$conffile" "$symlink"
	sudo service nginx restart

} &>> "$LOGFILE"

	log_end_msg 0

	return 0
}

#                                                             INSTALL_CERTBOT()
###############################################################################
install_certbot()
{
	local -r domain="$domainlabel.com"

	install_apt_package software-properties-common

	{
		sudo add-apt-repository --assume-yes universe
		sudo add-apt-repository --assume-yes ppa:certbot/certbot
		sudo apt-get update
	} &>> "$LOGFILE"

	install_apt_package certbot
	install_apt_package python-certbot-nginx
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
		sudo rm "$apt_source_dir/$apt_source_fn" &>> "$LOGFILE"
		log_action_end_msg $?
	fi

	if [[ -f "$mongo_service_dir/$mongo_service_fn" ]];
	then
		log_action_begin_msg "Removing system service file $mongo_service_fn"
		sudo rm "$mongo_service_dir/$mongo_service_fn" &>> "$LOGFILE"
		log_action_end_msg $?
	fi

	return 0
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
	local -r basedir="/var/www/$domainlabel"


	if sudo service --status-all | grep --fixed-strings --quiet "$service";
	then
		log_action_begin_msg "Stopping system service $service"
		sudo systemctl stop "$service" &>> "$LOGFILE";
		log_action_end_msg 0
	fi

	if command -v pm2 &>> "$LOGLEVEL";
	then
		log_action_begin_msg "Removing pm2 processes"
		grep --quiet "$domainlabel-frontend" < <(pm2 ls) && \
			pm2 delete "$domainlabel-frontend" &>> "$LOGLEVEL"
		grep --quiet "$domainlabel-backend" < <(pm2 ls)  && \
			pm2 delete "$domainlabel-backend" &>> "$LOGLEVEL"
		# removes pm2 startup scripts
		bash -c "$(pm2 unstartup | tail --lines 1)" &>> "$LOGLEVEL"
		pm2 save &>> "$LOGLEVEL"
		log_action_end_msg 0
	fi

	if is_apt_package_installed "$package";
	then
		log_action_begin_msg "Deinstalling $package"
		[[ -d /var/log/mongodb ]] &&
			sudo rm --recursive /var/log/mongodb &>> "$LOGLEVEL"
		[[ -d /var/lib/mongodb ]] && \
			sudo rm --recursive /var/lib/mongodb &>> "$LOGLEVEL"
		sudo apt-get --assume-yes --allow-change-held-packages \
			purge "$package" &>> "$LOGLEVEL"
		log_action_end_msg $?
	fi

	sudo rm --recursive --force "$basedir" &>> "$LOGLEVEL"

	remove_conf_files

	return 0
}


#                                                                          BODY
###############################################################################

# code in here only gets executed if script is run directly on the cmdline
if [ "${BASH_SOURCE[0]}" == "$0" ];
then

	# source lsb init function file for advanced log functions
	declare LOGFILE

	LOGFILE=$(mktemp /tmp/"$(date +"%Y-%m-%d_%T_XXXXXX")")
	echo "Detailed log goes to $LOGFILE"

	if [[ ! -f /lib/lsb/init-functions ]];
	then
		>&2 echo "Error sourcing /lib/lsb/init-functions"
		exit 1
	fi
	. /lib/lsb/init-functions

	# pass whole parameter list to main
	if ! main "$@";
	then
		log_begin_msg "Script error"
		log_end_msg 1
		exit 1
	fi

fi

