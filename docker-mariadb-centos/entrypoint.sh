set -e

TIMEZONE=${TIMEZONE:-Asia/Shanghai}
TEMP_SQL_FILE='/tmp/mysql-first-time.sql'
DEFAULT_CONF=${DEFAULT_CONF:-enable}
RANDOM_PASS=$(date +"%s%N"| sha256sum | base64 | head -c 16) && MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-${RANDOM_PASS}}
REPLICATION_USERNAME=${REPLICATION_USERNAME:-replication}
WSREP_SST_METHOD=${WSREP_SST_METHOD:-xtrabackup-v2}

[ -n "$TIMEZONE" ] && { rm -rf /etc/localtime && ln -s /usr/share/zoneinfo/$TIMEZONE /etc/localtime; }
[ "${1:0:1}" = '-' ] && set -- mysqld "$@"
[ -z "$@" ] && set -- mysqld "$@"

if [[ ${DEFAULT_CONF} =~ ^[dD][iI][sS][aA][bB][lL][eE]$ ]]; then
	sed -ri "s@^(port).*@\1=${PORT1}@" /etc/my.cnf
	sed -ri "s@^(basedir).*@\1=${INSTALL_DIR}@" /etc/my.cnf
	sed -ri "s@^(datadir).*@\1=${DATA_DIR}@" /etc/my.cnf
	sed -ri "s@^(pid-file).*@\1=${DATA_DIR}/mysql.pid@" /etc/my.cnf
	sed -ri "s@^(max_connections).*@\1=${MAX_CONNECTIONS}@" /etc/my.cnf
	sed -ri "s@^(max_allowed_packet).*@\1=${MAX_ALLOWED_PACKET}@" /etc/my.cnf
	sed -ri "s@^(query_cache_size).*@\1=${QUERY_CACHE_SIZE}@" /etc/my.cnf
	sed -ri "s@^(query_cache_type).*@\1=${QUERY_CACHE_TYPE}@" /etc/my.cnf
	sed -ri "s@^(innodb_log_file_size).*@\1=${INNODB_LOG_FILE_SIZE}@" /etc/my.cnf
	sed -ri "s@^(sync_binlog).*@\1=${SYNC_BINLOG}@" /etc/my.cnf
	sed -ri "s@^(innodb_buffer_pool_size).*@\1=${INNODB_BUFFER_POOL_SIZE}@" /etc/my.cnf
	sed -ri "s@^(innodb_old_blocks_time).*@\1=${INNODB_OLD_BLOCKS_TIME}@" /etc/my.cnf
	sed -ri "s@^(innodb_flush_log_at_trx_commit).*@\1=${INNODB_FLUSH_LOG_AT_TRX_COMMIT}@" /etc/my.cnf
	sed -ri "s@/data/mariadb@${DATA_DIR}@" /etc/my.cnf
	[ -n "$INNODB_FLUSH_METHOD" ] && sed -ri "/^innodb_flush_log_at_trx_commit/a innodb_flush_method=${INNODB_FLUSH_METHOD}" /etc/my.cnf
fi

if [ "$1" = 'mysqld' ]; then
	if [[ "${GALERA}" =~ ^[eE][nN][aA][bB][lL][eE]$ ]]; then
		if [ -z "$CLUSTER_NAME" ]; then
			echo >&2 'error:  missing CLUSTER_NAME'
			echo >&2 '  Did you forget to add -e CLUSTER_NAME=... ?'
			exit 1
		fi

		if [ -z "$NODE_NAME" ]; then
			echo >&2 'error:  missing NODE_NAME'
			echo >&2 '  Did you forget to add -e NODE_NAME=... ?'
			exit 1
		fi

		if [ -z "$CLUSTER_ADDRESS" ]; then
			echo >&2 'error:  missing CLUSTER_ADDRESS'
			echo >&2 '  Did you forget to add -e CLUSTER_ADDRESS=... ?'
			exit 1
		fi

		if [ -z "$WSREP_NODE_ADDRESS" ]; then
			echo >&2 'error:  missing WSREP_NODE_ADDRESS'
			echo >&2 '  Did you forget to add -e WSREP_NODE_ADDRESS=... ?'
			exit 1
		fi

		if [[ ! "$WSREP_SST_METHOD" =~ ^(mysqldump|xtrabackup(-v2)?|rsync|rsync_wan)$ ]]; then
			echo >&2 'error:  missing WSREP_SST_METHOD'
			echo >&2 '  You must be used  -e WSREP_SST_METHOD=[mysqldump|xtrabackup|xtrabackup-v2|rsync|rsync_wan] '
			exit 1
		fi
	fi

	if [ ! -d "$DATA_DIR/mysql" ]; then
		if [[ "${GALERA}" =~ ^[eE][nN][aA][bB][lL][eE]$ ]] && [[ -z "$REPLICATION_PASSWORD" ]]; then
			echo >&2 'error:  missing REPLICATION_PASSWORD'
			echo >&2 '  Did you forget to add -e REPLICATION_PASSWORD=... ?'
			exit 1
		fi

		echo 'Running mysql_install_db ...'
		#cd $INSTALL_DIR/ && $INSTALL_DIR/scripts/mysql_install_db --user=mysql --datadir="$DATA_DIR" >/dev/null 2>&1
		mysql_install_db --user=mysql --datadir="$DATA_DIR" --defaults-file=/etc/my.cnf #>/dev/null 2>&1
		echo -e "\033[44;37;1mFinished mysql_install_db\033[39;49;0m,\033[45;37;1mMariaDB Root Password is ${MYSQL_ROOT_PASSWORD}\033[39;49;0m"

		cat > "$TEMP_SQL_FILE" <<-EOF
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user;
			GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
			--GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
			--GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
			DROP DATABASE IF EXISTS test;
		EOF

		if [[ "${GALERA}" =~ ^[eE][nN][aA][bB][lL][eE]$ ]]; then
			#echo "GRANT ALL PRIVILEGES ON *.* TO '${REPLICATION_USERNAME}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}' WITH GRANT OPTION ;" >> "$TEMP_SQL_FILE"
			cat >> "$TEMP_SQL_FILE" <<-EOF
				-- CREATE USER '${REPLICATION_USERNAME}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}' ;
				-- GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT,FILE ON *.* TO '${REPLICATION_USERNAME}'@'%' ;
				-- CREATE USER '${REPLICATION_USERNAME}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
				GRANT ALL PRIVILEGES ON *.* TO '${REPLICATION_USERNAME}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
				--GRANT SUPER,RELOAD,LOCK TABLES,REPLICATION CLIENT,REPLICATION SLAVE,FILE ON *.* TO '${REPLICATION_USERNAME}'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
			EOF
		fi

		[ "$MYSQL_DATABASE" ] && echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$TEMP_SQL_FILE"

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$TEMP_SQL_FILE"
			[ "$MYSQL_DATABASE" ] && echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$TEMP_SQL_FILE"
		fi

		echo "FLUSH PRIVILEGES ;" >> "$TEMP_SQL_FILE"
		set -- "$@" --init-file="$TEMP_SQL_FILE"
	fi

	chown -R mysql:mysql "$DATA_DIR"

	if [[ "${GALERA}" =~ ^[eE][nN][aA][bB][lL][eE]$ ]]; then
		WSREP_PROVIDER=${WSREP_PROVIDER:-/usr/lib64/galera/libgalera_smm.so}
		# append galera specific run options
		set -- "$@" \
			--wsrep_provider="${WSREP_PROVIDER}" \
			--wsrep_cluster_address="${CLUSTER_ADDRESS}" \
			--wsrep_cluster_name="${CLUSTER_NAME}" \
			--wsrep_node_address="${WSREP_NODE_ADDRESS}" \
			--wsrep_node_name="${NODE_NAME}" \
			--wsrep_sst_method="${WSREP_SST_METHOD}" \
			--wsrep_sst_auth="${REPLICATION_USERNAME}:${REPLICATION_PASSWORD}"
			#--wsrep_sst_receive_address="${WSREP_NODE_ADDRESS}"
	fi
fi

#echo >&2 "$@"
exec "$@"
