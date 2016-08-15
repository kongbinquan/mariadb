#!/bin/bash
#########################################################################
# File Name: entrypoint.sh
# Author: LookBack
# Email: admin#dwhd.org
# Version:
# Created Time: 2016年07月11日 星期一 14时41分21秒
#########################################################################

set -e
#DATA_DIR=/var/lib/mysql
IP=$(awk '{for (i=1;i<=NF;i++)if($i!~/:/){print $i;exit}}' <<< $(hostname -i))


# set timezone if it was specified
TIMEZONE=${TIMEZONE:-Asia/Shanghai}
[ "$(id -u)" = '0' ] && { rm -rf /etc/localtime && ln -sv /usr/share/zoneinfo/$TIMEZONE /etc/localtime; }

#Chown data dir
[ "$(id -u)" = '0' ] && chown -R mysql:mysql ${DATA_DIR}

# apply environment configuration
sed -i -e "s@^\[mysqld\]@\[mysqld\]\ndatadir=${DATA_DIR}@" /etc/mysql/my.cnf
sed -i -e "s@^port.*=.*@port=${PORT1}@" /etc/mysql/my.cnf
sed -i -e "s@^#max_connections.*=.*@max_connections=${MAX_CONNECTIONS}@" /etc/mysql/my.cnf
sed -i -e "s@^max_allowed_packet.*=.*@max_allowed_packet=${MAX_ALLOWED_PACKET}@" /etc/mysql/my.cnf
sed -i -e "s@^query_cache_size.*=.*@query_cache_size=${QUERY_CACHE_SIZE}@" /etc/mysql/my.cnf

sed -ri "s@^(#)?(innodb_log_file_size)(\s{1,})?=.*@\2=${INNODB_LOG_FILE_SIZE}@" /etc/mysql/my.cnf
sed -ri "s@^(#)?(query_cache_type)(\s{1,})?.*@\2=${QUERY_CACHE_TYPE}@" /etc/mysql/my.cnf
sed -ri "s@^(#)?(sync_binlog)(\s{1,})?.*@\2=${SYNC_BINLOG}@" /etc/mysql/my.cnf
sed -ri "s@^(#)?(innodb_buffer_pool_size)(\s{1,})?.*@\2=${INNODB_BUFFER_POOL_SIZE}@" /etc/mysql/my.cnf
sed -ri "s@^(#)?(innodb_old_blocks_time)(\s{1,})?.*@\2=${INNODB_OLD_BLOCKS_TIME}@" /etc/mysql/my.cnf
sed -ri "s@^(#)?(innodb_flush_log_at_trx_commit)(\s{1,})?.*@\2=${INNODB_FLUSH_LOG_AT_TRX_COMMIT}@" /etc/mysql/my.cnf
#sed -ri "s@^(#)?()(\s{1,})?.*@\2=${}@" /etc/mysql/my.cnf
#sed -ri "s@^(#)?()(\s{1,})?.*@\2=${}@" /etc/mysql/my.cnf
#sed -ri "s@^(#)?()(\s{1,})?.*@\2=${}@" /etc/mysql/my.cnf
#sed -ri "s@^(#)?()(\s{1,})?.*@\2=${}@" /etc/mysql/my.cnf

#sed -i -e "s/^\[mysqld\]/\[mysqld\]\nquery_cache_type=${QUERY_CACHE_TYPE}/" /etc/mysql/my.cnf
#sed -i -e "s/^\[mysqld\]/\[mysqld\]\nsync_binlog=${SYNC_BINLOG}/" /etc/mysql/my.cnf
#sed -i -e "s/^\[mysqld\]/\[mysqld\]\ninnodb_buffer_pool_size=${INNODB_BUFFER_POOL_SIZE}/" /etc/mysql/my.cnf
#sed -i -e "s/^\[mysqld\]/\[mysqld\]\ninnodb_old_blocks_time=${INNODB_OLD_BLOCKS_TIME}/" /etc/mysql/my.cnf
#sed -i -e "s/^\[mysqld\]/\[mysqld\]\ninnodb_flush_log_at_trx_commit=${INNODB_FLUSH_LOG_AT_TRX_COMMIT}/" /etc/mysql/my.cnf

[ -n "$INNODB_FLUSH_METHOD" ] && sed -i -e "s/^\[mysqld\]/\[mysqld\]\ninnodb_flush_method=${INNODB_FLUSH_METHOD}/" /etc/mysql/my.cnf

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$0" "$@"
fi

if [ "$1" = 'mysqld' -a "$(id -u)" = '0' ]; then
	exec su-exec mysql "$0" "$@"
fi

if [ "$1" = 'mysqld' ]; then
	DATA_DIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
	sed -i -e "s@^\[mysqld\]@\[mysqld\]\nlog_error=${DATA_DIR}mysql-error.log@" /etc/mysql/my.cnf
	[ -n "$GALERA" ] && {
		[ -z "$CLUSTER_NAME" ] && {
			echo >&2 'error:  missing CLUSTER_NAME'
			echo >&2 '  Did you forget to add -e CLUSTER_NAME=... ?'
			exit 1; }

		[ -z "$NODE_NAME" ] && {
			echo >&2 'error:  missing NODE_NAME'
			echo >&2 '  Did you forget to add -e NODE_NAME=... ?'
			exit 1; }

		[ -z "$CLUSTER_ADDRESS" ] && {
			echo >&2 'error:  missing CLUSTER_ADDRESS'
			echo >&2 '  Did you forget to add -e CLUSTER_ADDRESS=... ?'
			exit 1; }

		[ -z "$CLUSTER_NODE_ADDRESS" ] && {
			echo >&2 'error:  missing CLUSTER_NODE_ADDRESS'
			echo >&2 '  Did you forget to add -e CLUSTER_NODE_ADDRESS=... ?'
			exit 1; }

		[ -n "$CLUSTER_METHOD" ] && {
			if [[ ! "$CLUSTER_METHOD" =~ ^(mysqldump|xtrabackup(-v2)?|rsync(_wan)?)$ ]]; then
				echo >&2 'error:  missing CLUSTER_METHOD'
				echo >&2 '  You must be used  -e CLUSTER_METHOD=[mysqldump|xtrabackup|xtrabackup-v2|rsync|rsync_wan] '
				exit 1
			fi; } || {
			CLUSTER_METHOD=xtrabackup-v2; }; } || {
		rm -rf /etc/mysql/my.cnf.d/galera.cnf; }

	[ -n ${TUKUDB_ENGINE} ] && sed -i -e "s/^\[mysqld\]/\[mysqld\]\nplugin-load-add=ha_tokudb.so/" /etc/mysql/my.cnf
	if [ ! -d "$DATA_DIR/mysql" ]; then
		if [ -n "$GALERA" -a -z "$REPLICATION_PASSWORD" ]; then
			echo >&2 'error:  missing REPLICATION_PASSWORD'
			echo >&2 '  Did you forget to add -e REPLICATION_PASSWORD=... ?'
			exit 1
		fi
		
		echo 'Running mysql_install_db ...'
		mysql_install_db --datadir="$DATA_DIR"
		echo 'Finished mysql_install_db'
		
		tempSqlFile='/tmp/mysql-first-time.sql'
		cat > "$tempSqlFile" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			
			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;

			DROP DATABASE IF EXISTS test;
		EOSQL

		if [ -n "$GALERA" ]; then
			cat >> "$tempSqlFile" <<-EOSQL
			CREATE USER 'replication'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
			GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'replication'@'%';
			EOSQL
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
		fi
		
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"
			
			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
			fi
		fi
		
		echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
		
		set -- "$@" --init-file="$tempSqlFile"
	fi

	if [ -n "$GALERA" ]; then
		# append galera specific run options

		set -- "$@" \
		--wsrep_cluster_name="$CLUSTER_NAME" \
		--wsrep_cluster_address="$CLUSTER_ADDRESS" \
		--wsrep_node_name="$NODE_NAME" \
		--wsrep_sst_auth="replication:$REPLICATION_PASSWORD" \
		--wsrep_sst_receive_address=$IP
	fi

	if [ -n "$LOG_BIN" ]; then
		set -- "$@" --log-bin="$LOG_BIN"
		chown mysql:mysql $(dirname $LOG_BIN)
	fi

	if [ -n "$LOG_BIN_INDEX" ]; then
		set -- "$@" --log-bin-index="$LOG_BIN_INDEX"
		chown mysql:mysql $(dirname $LOG_BIN)
	fi
fi

exec "$@"
