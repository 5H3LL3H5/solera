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

# deug flag
declare DEBUG						# ON enables debug output

# package versions
declare MONGODB_VERSION
declare NODEJS_VERSION

# domain
declare FQDN						# full qualified domain name

# frontand and backend locations
declare BACKENDURI
declare FRONTENDURI

# database settings
declare DBHOSTNAME
declare DBPORT
declare DBNAME
declare DBUSERNAME
declare DBPASSWORD

# backend settings
declare CLIENTID
declare CLIENTSECRET
declare KEYID
declare REGION
declare ACCESSKEY
declare BUCKET
declare BACKENDPORT

# frontend settings
declare FRONTENDPORT


# script globals evaluated at runtime
declare PID_LOG						# holds process id of debug stream
declare DOMAIN						# cstenzel.com
declare DOMAINLABEL					# cstenzel
declare BASEDIR						# /var/www/$DOMAIN


#                                                                     CLEANUP()
#
# cleanup on exit, signal handler
###############################################################################
cleanup()
{
		[[ -n $PID_LOG ]] && kill -9 "$PID_LOG"
}

#                                                                        MAIN()
#
# main control function
###############################################################################
main()
{
	local -r package="mongodb-org"

	check_config_file

	LOGFILE=$(mktemp /tmp/"$(date +"%Y-%m-%d_%T_XXXXXX")")
	echo "Detailed log goes to $LOGFILE"

	if [[ "$DEBUG" == "ON" ]];
	then
		# command output to stdout
		( tail -f "$LOGFILE" ) &
		PID_LOG=$!
	fi

	install_package_dependencies

	install_mongodb_package

	# delete any runnning pm2 domain related processes
	delete_pm2_process "$DOMAINLABEL-backend"
	delete_pm2_process "$DOMAINLABEL-frontend"

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
		--domain "$DOMAIN" \
		--domain "$FQDN" \
		--domain admin."$DOMAIN" &>> "$LOGFILE"

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
	local -r config="./installconfig"

	# shellcheck source=./installconfig
	[[ -f "$config" ]] && source "$config"

	if [[ \
			-z "$MONGODB_VERSION" || \
			-z "$NODEJS_VERSION" || \
			-z "$FQDN" || \
			-z "$BACKENDURI" || \
			-z "$FRONTENDURI" || \
			-z "$DBHOSTNAME" || \
			-z "$DBPORT" || \
			-z "$DBNAME" || \
			-z "$DBUSERNAME" ||  \
			-z "$DBPASSWORD" || \
			-z "$CLIENTID" || \
			-z "$CLIENTSECRET" || \
			-z "$KEYID" || \
			-z "$REGION" || \
			-z "$ACCESSKEY" || \
			-z "$BUCKET" || \
			-z "$BACKENDPORT" || \
			-z "$FRONTENDPORT" \
	]];
	then
		echo "Invalid config file."
		exit 1
	fi

	DOMAIN=${FQDN#www.}				# cstenzel.com
	DOMAINLABEL=${DOMAIN%.*}		# cstenzel
	BASEDIR="/var/www/$DOMAINLABEL"

	exit 1

	return 0	      # exit success
}

#                                                INSTALL_PACKAGE_DEPENDENCIES()
#
# installs required packages
###############################################################################
install_package_dependencies()
{
	local -r node_version="$NODEJS_VERSION"

	local -r nginx_flavour="light"
	local -r viaapt="git nginx-$nginx_flavour sed coreutils systemd
					init-system-helpers ca-certificates curl"
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
		log_action_begin_msg "Preparing nodejs installation"
		sudo --preserve-env \
			bash - < <(curl --silent --location \
			http://deb.nodesource.com/setup_"$node_version".x) \
			&>> "$LOGFILE"
		log_action_end_msg 0
		install_apt_package nodejs
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
	local -r mongodb_version="$MONGODB_VERSION"

	local -r lsb_release_name=$(lsb_release --codename --short)
	local -r apt_source_fn="mongodb-org-$mongodb_version.list"
	local -r apt_source_dir="/etc/apt/sources.list.d/"
	local -r service="mongod"
	local -r mongo_service_fn="$service.service"

	local -r package="mongodb-org"

	if is_apt_package_installed "$package";
	then
		return 1;
	fi

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
	sudo tee /lib/systemd/system/"$mongo_service_fn" >> "$LOGFILE"
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
		log_action_end_msg 0
		setup_mongo_database
		return 0
	fi
}


#                                                        SETUP_MONGO_DATABASE()
#
# inital database setup
###############################################################################
setup_mongo_database()
{
	local -r dbusername="$DBUSERNAME"
	local -r dbpassword="$DBPASSWORD"
	local -r dbname="$DBNAME"

	local -r service="mongod"

	log_action_begin_msg "Deleting MongoDB user $dbusername"
	mongo --quiet --eval "
	db=db.getSiblingDB(\"$dbname\");
	db.dropUser(\"$dbusername\")" &>> "$LOGFILE"
	log_action_end_msg $?

	log_action_begin_msg "Adding inital user $dbusername to database"
	mongo --quiet --eval "
		db=db.getSiblingDB(\"$dbname\");
		db.createUser({
		user:\"$dbusername\", \
		pwd:\"$dbpassword\", \
		roles:[{role:'root', db:'$dbname'}]})" &>> "$LOGFILE"
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
	local -r basedir="$BASEDIR"
	local -r frontenduri="$FRONTENDURI"
	local -r backenduri="$BACKENDURI"

	if [[ ! -d "$basedir" ]];
	then
		sudo mkdir --parents "$basedir" &>> "$LOGFILE"
		sudo chown --recursive "$USER:$(id --group --name)" "$basedir" \
			&>> "$LOGFILE"
	fi

	if [[ ! -d "$basedir/backend" ]];
	then
		log_action_begin_msg "Cloning backend"
		git -C "$basedir" clone "$backenduri" backend &>> "$LOGFILE"
		log_action_end_msg $?
	else
		log_action_begin_msg "Pulling backend"
		git -C "$basedir/backend" pull &>> "$LOGFILE"
		log_action_end_msg $?
	fi

	if [[ ! -d "$basedir/frontend" ]];
	then
		log_action_begin_msg "Cloning frontend"
		git -C "$basedir" clone "$frontenduri" "frontend" &>> "$LOGFILE"
		log_action_end_msg $?
	else
		log_action_begin_msg "Pulling frontend"
		git -C "$basedir/frontend" pull &>> "$LOGFILE"
		log_action_end_msg $?
	fi
}


#                                             INSTALL_JAVASCRIPT_DEPENDENCIES()
###############################################################################
install_javascript_dependencies()
{
	local -r basedir="$BASEDIR"

	local -r curwd="$(pwd)"

	sudo chown -R "$USER":"$(id -gn "$USER")" "$HOME"/.config &>> "$LOGFILE"

	cd "$basedir/backend" || return 1
	log_action_begin_msg "Install backend dependencies"
	npm update &>> "$LOGFILE"
	log_action_end_msg $?
	cd "$curwd" || return 1

	cd "$basedir/frontend" || return 1
	log_action_begin_msg "Install frontend dependencies"
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
	local -i port="$FRONTENDPORT"
	local -r basedir="$BASEDIR"

	local -r conffile="$basedir/frontend/package.json"
	local -r pattern1='"dev": "next dev"'
	local -r pattern2='"start": "next start"'

	log_action_begin_msg "Adapting frontend port"
	sed --in-place "s/$pattern1/${pattern1:0:-1} -p $port\"/" "$conffile"
	sed --in-place "s/$pattern2/${pattern2:0:-1} -p $port\"/" "$conffile"
	log_action_end_msg $?
}


#                                                          ADAPT_FRONTEND_URL()
###############################################################################
adapt_frontend_url()
{
	local -r basedir="$BASEDIR"
	local -r conffile="$basedir/frontend/constants/projectSettings.js"

	local -r pattern1="export const baseUrl"
	local -r pattern2="https:\/\/admin.cbdbene.com"
	local -r httpsurl="https:\/\/admin.$DOMAINLABEL.com"

	log_action_begin_msg "Adapting frontend url"
	sed --in-place "s/^\($pattern1.*= \).*$/\1\"$httpsurl\";/" "$conffile"
	sed --in-place "s/$pattern2/$httpsurl/" "$conffile"
	log_action_end_msg $?
}


#                                                              BUILD_FRONTEND()
###############################################################################
build_frontend()
{
	local -r basedir="$BASEDIR"

	local -r curwd="$(pwd)"
	local -r -i max_runs=10
	local -i successful_build=1

	log_action_begin_msg "Building frontend dependencies"

	cd "$basedir/frontend" || return 1
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
	local -r basedir="$BASEDIR"
	local -r dbusername="$DBUSERNAME"
	local -r dbpassword="$DBPASSWORD"
	local -r dbname="$DBNAME"
	local -r dbhostname="$DBHOSTNAME"
	local -r clientid="$CLIENTID"
	local -r clientsecret="$CLIENTSECRET"
	local -r keyid="$KEYID"
	local -r region="$REGION"
	local -r accesskey="$ACCESSKEY"
	local -r bucket="$BUCKET"
	local -r -i backendport="$BACKENDPORT"
	local -r -i dbport="$DBPORT"

	local -r envfile=".env"
	local -r clienturl="https://$DOMAINLABEL.com"
	local -r serverurl="https://$DOMAINLABEL.com"

	cat <<-EOF > "$basedir/backend/$envfile"
		PORT=$backendport
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
	local -r basedir="$BASEDIR"
	local -r instance_name="$DOMAINLABEL-backend"

	local -r curwd="$(pwd)"

	# delete running pm2 backend
	delete_pm2_process "$instance_name"

	cd "$basedir/backend" || return 1
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
	local -r basedir="$BASEDIR"
	local -r instance_name="$DOMAINLABEL-frontend"

	local -r curwd="$(pwd)"

	# delete running pm2 frontend
	delete_pm2_process "$instance_name"

	cd "$basedir/frontend" || return 1
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
	local -r -i frontend_port="$FRONTENDPORT"
	local -r -i backend_port="$BACKENDPORT"
	local -r conffile="/etc/nginx/sites-available/$DOMAIN"
	local -r symlink="/etc/nginx/sites-enabled/$DOMAIN"

	local -r nginx_flavour="light"

	log_action_begin_msg "Configure and restart webserver"

	{
		[[ -e "$symlink" ]] && sudo rm "$symlink"
		[[ -f "$conffile" ]] && sudo rm "$conffile"

		cat << EOF | \
		sudo tee --append "$conffile"
		server {
			listen 80;
			server_name $DOMAIN $FQDN;
			location / {
				return 301 https://\$host\$request_uri;
			}
		}

		server {
			listen 443 ssl;
			listen [::]:443 ssl ;
			server_name $DOMAIN $FQDN;
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
			server_name admin.$DOMAIN;
			location / {
				return 301 https://\$host\$request_uri;
			}
		}

		# Point backend domain name to port
		server {
			listen 443 ssl;
			index index.html index.htm index.nginx-debian.html;
			server_name admin.$DOMAIN;
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
	install_apt_package software-properties-common

	{
		sudo add-apt-repository --yes universe
		sudo add-apt-repository --yes ppa:certbot/certbot
		sudo apt-get update
	} &>> "$LOGFILE"

	install_apt_package certbot
	install_apt_package python-certbot-nginx
}


#                                                                          BODY
###############################################################################

# code in here only gets executed if script is run directly on the cmdline
if [ "${BASH_SOURCE[0]}" == "$0" ];
then

	trap cleanup EXIT

	# source lsb init function file for advanced log functions
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

