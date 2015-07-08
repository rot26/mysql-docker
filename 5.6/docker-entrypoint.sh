#!/bin/bash
set -e

get_option () {
	local section=$1
	local option=$2
	local default=$3
	# my_print_defaults can output duplicates, if an option exists both globally and in
	# a custom config file. We pick the last occurence, which is from the custom config.
	ret=$(my_print_defaults $section | grep '^--'${option}'=' | cut -d= -f2- | tail -n1)
	[ -z $ret ] && ret=$default
	echo $ret
}

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
	# Get config
	DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
	SOCKET=$(get_option  mysqld socket "$DATADIR/mysql.sock")
	PIDFILE=$(get_option mysqld pid-file "/var/run/mysqld/mysqld.pid")

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
			echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
			exit 1
		fi

		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo 'Running mysql_install_db'
		mysql_install_db --user=mysql --datadir="$DATADIR" --rpm --keep-my-cnf
		echo 'Finished mysql_install_db'

		mysqld --user=mysql --datadir="$DATADIR" --skip-networking &
		for i in $(seq 30 -1 0); do
			[ -S "$SOCKET" ] && break
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ $i = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		# These statements _must_ be on individual lines, and _must_ end with
		# semicolons (no line breaks or comments are permitted).
		# TODO proper SQL escaping on ALL the things D:

		tempSqlFile=$(mktemp /tmp/mysql-first-time.XXXXXX.sql)
		cat > "$tempSqlFile" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			
			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
		EOSQL

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" >> "$tempSqlFile"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" >> "$tempSqlFile"
			fi
		fi

		# Create a replication user if MYSQL_REPLICA_USER is set
		# Single user created on master and slaves for ease of use.
		# Consider creating a different account for each slave.

		if [ "$MYSQL_REPLICA_USER" ]; then
			if [ -z "$MYSQL_REPLICA_PASS" ]; then
				echo >&2 'error: MYSQL_REPLICA_USER set, but MYSQL_REPLICA_PASS not set'
				echo >&2 '  Did you forget to add -e MYSQL_REPLICA_PASS=... ?'
				exit 1
			fi

			echo "CREATE USER '"$MYSQL_REPLICA_USER"'@'%' IDENTIFIED BY '"$MYSQL_REPLICA_PASS"' ;" >> "$tempSqlFile"
			echo "GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICA_USER'@'%' ; " >> "$tempSqlFile"

			# REPLICATION CLIENT privileges are required to get master position
			echo "GRANT REPLICATION CLIENT ON *.* TO '$MYSQL_REPLICA_USER'@'%' ; " >> "$tempSqlFile"
		fi

		# On the slave: point to a master server

		if [ "$MYSQL_MASTER_SERVER" ]; then

			MYSQL_MASTER_PORT=${MYSQL_MASTER_PORT:-3306}
			MYSQL_MASTER_WAIT_TIME=${MYSQL_MASTER_WAIT_TIME:-3}

			# Wait for the master to come up
			# Do at least one iteration

			for i in $(seq $((MYSQL_MASTER_WAIT_TIME + 1))); do
				if ! mysql "-u$MYSQL_REPLICA_USER" "-p$MYSQL_REPLICA_PASS" "-h$MYSQL_MASTER_SERVER" -e 'select 1;' |grep -q 1; then
					echo >&2 "Waiting for $MYSQL_REPLICA_USER@$MYSQL_MASTER_SERVER"
					sleep 1
				else
					break
				fi
			done

			if [ "$i" -gt "$MYSQL_MASTER_WAIT_TIME" ]; then
				echo 2>&1 "error: Master is not reachable after $MYSQL_MASTER_WAIT_TIME seconds."
				echo >&2 '  Did you try increasing the wait time with -e MYSQL_MASTER_WAIT_TIME=... ?'
				exit 1
			fi

			# Get master position and set it on the slave.
			# IMPORTANT: MASTER_PORT and MASTER_LOG_POS must not be quoted
			# Note: Replication cannot use Unix socket files. You must be able to connect to the master MySQL server using TCP/IP.

			MasterPosition=$(mysql \
				"-u$MYSQL_REPLICA_USER" \
				"-p$MYSQL_REPLICA_PASS" \
				"-h$MYSQL_MASTER_SERVER" \
				-e "show master status \G" \
				| awk '/Position/ {print $2}')
			MasterFile=$(mysql  \
				"-u$MYSQL_REPLICA_USER" \
				"-p$MYSQL_REPLICA_PASS" \
				"-h$MYSQL_MASTER_SERVER" \
				-e "show master status \G" \
				| awk '/File/ {print $2}')

			echo "CHANGE MASTER TO \
				MASTER_HOST='$MYSQL_MASTER_SERVER', \
				MASTER_PORT=$MYSQL_MASTER_PORT, \
				MASTER_USER='$MYSQL_REPLICA_USER', \
				MASTER_PASSWORD='$MYSQL_REPLICA_PASS', \
				MASTER_LOG_FILE='$MasterFile', \
				MASTER_LOG_POS=$MasterPosition ;" \
				>> "$tempSqlFile"
			echo "START SLAVE ;"  >> "$tempSqlFile"

		fi

		echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"

		mysql --protocol=socket -uroot < "$tempSqlFile"

		rm -f "$tempSqlFile"
		kill $(cat $PIDFILE)
		for i in $(seq 30 -1 0); do
			[ -f "$PIDFILE" ] || break
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ $i = 0 ]; then
			echo >&2 'MySQL hangs during init process.'
			exit 1
		fi
		echo 'MySQL init process done. Ready for start up.'
	fi

	chown -R mysql:mysql "$DATADIR"
fi

exec "$@"
