#! /usr/bin/env bash

SED_E="sed -E"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GENESIS_BE_ROOT="/genesis-back"
GENESIS_BE_ROOT_LOG_DIR="/var/log/go-genesis"
GENESIS_BE_ROOT_DATA_DIR="$GENESIS_BE_ROOT/data"
GENESIS_BE_BIN_DIR="$GENESIS_BE_ROOT/bin"
GENESIS_BE_BIN_BASENAME="go-genesis"
GENESIS_BE_BIN_PATH="$GENESIS_BE_BIN_DIR/$GENESIS_BE_BIN_BASENAME"

GENESIS_DB_NAME_PREFIX="genesis"
GENESIS_DB_HOST="genesis-db"

GENESIS_SCRIPTS_DIR="/genesis-scripts"
GENESIS_APPS_DIR="/genesis-apps"

CLIENT_PORT_SHIFT=7000

CENT_SECRET="4597e75c-4376-42a6-8c1f-7e3fc7eb2114"
CENT_URL="http://genesis-cf:8000"

SUPERVISOR_BASE_CONF_DIR="/etc/supervisor"
SUPERVISOR_CONF_D_DIR="$SUPERVISOR_BASE_CONF_DIR/conf.d"
SUPERVISOR_CONF_PATH="$SUPERVISOR_BASE_CONF_DIR/supervisord.conf"
SUPERVISOR_GENESIS_BE_NODE1_CONF_PATH="$SUPERVISOR_CONF_D_DIR/go-genesis.conf"

read -r -d '' SUPERVISOR_GENESIS_BE_NODE1_CONF << EOM
[program:go-genesis]
command=$GENESIS_BE_BIN_PATH start --config=$GENESIS_BE_ROOT_DATA_DIR/node1/config.toml
user = root
stdout_events_enabled = true
stderr_events_enabled = true
autorestart = true
EOM

get_genesis_be_supervisor_conf() {
    local conf
    if [ -e "$SUPERVISOR_GENESIS_BE_NODE1_CONF_PATH" ]; then
        conf="$(cat "$SUPERVISOR_GENESIS_BE_NODE1_CONF_PATH")"
    fi
    if [ -z "$conf" ]; then
        conf="$SUPERVISOR_GENESIS_BE_NODE1_CONF"
    fi
    if [ -z "$1" ] || [ "$1" == "1" ]; then
        [ -n "$conf" ] && echo "$conf"
    else
        [ -n "$conf" ] && echo "$conf" \
            | $SED_E "s/node1\//node$1\\//" \
            | $SED_E "s/program:([^]]+)/program:\1$1/"
    fi
}

setup_genesis_be_supervisor_conf() {
    [ -n "$SUPERVISOR_GENESIS_BE_CONF" ] \
        && echo "$SUPERVISOR_GENESIS_BE_CONF"
}

run_genesis_be_set_cmd() {
    local num cmd data_dir first_block_path db_name tcp_port http_port log_path
    local http_host
    local config_path run_cmd first_node_tcp_addr pid_path pid_data pid
    local run_status cnt lock_path sv_conf_path sed_pat update_sv reread_sv

    local key_id1 pr_key1 pub_key1 node_pub_key1 host1 http_port1 tcp_port1
    local key_id2 pr_key2 pub_key2 node_pub_key2 host2 http_port2 tcp_port2
    local key_id3 pr_key3 pub_key3 node_pub_key3 host3 http_port3 tcp_port3
    local key_id4 pr_key4 pub_key4 node_pub_key4 host4 http_port4 tcp_port4
    local key_id5 pr_key5 pub_key5 node_pub_key5 host5 http_port5 tcp_port5

    local key_ids pr_keys node_pub_keys
    local hosts tcp_ports tcp_addrs 
    local http_hosts http_ports api_urls

    [ -z "$1" ] && echo "Backend's set command isn't defined" && return 1
    cmd="$1"

    [ -z "$2" ] && echo "The number of backends isn't set" && return 2
    num="$2"

    echo "cmd: $cmd num: $num"

    if [ ! -d "$GENESIS_BE_ROOT_LOG_DIR" ]; then
        echo "Creating backend's root logs directory '$GENESIS_BE_ROOT_LOG_DIR' ..."
        mkdir -p "$GENESIS_BE_ROOT_LOG_DIR" || return $?
    fi
    
    if [ ! -d "$GENESIS_BE_ROOT_DATA_DIR" ]; then
        echo "Creating backend's root data directory '$GENESIS_BE_ROOT_DATA_DIR' ..."
        mkdir -p "$GENESIS_BE_ROOT_DATA_DIR" || return $?
    fi

    reread_sv="no"
    update_sv="no"

    for i in $(seq 1 $num); do
        data_dir="$GENESIS_BE_ROOT_DATA_DIR/node$i"
        config_path="$data_dir/config.toml"
        pid_path="$data_dir/go-genesis.pid"
        lock_path="$data_dir/go-genesis.lock"

        if [ ! -d "$data_dir" ]; then
            echo "Creating backend #$i data directory '$data_dir' ..."
            mkdir -p "$data_dir" || return $?
        fi

        case "$cmd" in
            create-configs)
                db_name="$GENESIS_DB_NAME_PREFIX$i"
                http_port=700$i
                log_path="node$i.log"

                if [ $i -eq 1 ]; then
                    first_block_path="$data_dir/FirstBlock"
                    tcp_port=7078
                    first_node_tcp_addr="127.0.0.1:$tcp_port"
                else
                    tcp_port=701$i
                fi

                echo "Creating config for backend node #$i/$num ..."
                run_cmd="$GENESIS_BE_BIN_PATH config \
                    --dataDir=$data_dir --firstBlock=$first_block_path \
                    --dbName=$db_name --dbHost=$GENESIS_DB_HOST \
                    --tcpPort=$tcp_port \
                    --httpHost=0.0.0.0 --httpPort=$http_port \
                    --centSecret=$CENT_SECRET --centUrl=$CENT_URL \
                    --logTo=$log_path" || return $?
                if [ $i -gt 1 ]; then
                    run_cmd="$run_cmd --nodesAddr=$first_node_tcp_addr"
                fi
                $run_cmd
                ;;

            gen-keys)
                echo "Generating keys for backend node #$i/$num ..."
                $GENESIS_BE_BIN_PATH generateKeys --config=$config_path \
                    || return $?
                ;;

            gen-first-block)
                [ $i -ne 1 ] && break
                echo "Generating keys for backend node #$i/$num ..."
                $GENESIS_BE_BIN_PATH generateFirstBlock --config=$config_path \
                    || return $?
                ;;

            init-dbs)
                echo "Initializing DB for backend node #$i/$num ..."
                $GENESIS_BE_BIN_PATH initDatabase --config=$config_path \
                    || return $?
                ;;

            start-bg)
                echo "Starting backend node #$i/$num as bg process ..."
                nohup $GENESIS_BE_BIN_PATH start --config=${config_path} 2>&1 &
                sleep 1
                ;;

            stop-bg)
                echo "Stopping backend node #$i/$num bg process ..."
                [ ! -e "$pid_path" ] && continue
                pid_data="$(cat "$pid_path")"
                if [ -n "$pid_data" ]; then
                    pid="$(echo "$pid_data" \
                        | $SED_E -n 's/.*"pid"[^:]*:[^"]*"([^"]+)".*/\1/p')"
                    if [ -n "$pid" ]; then
                        cnt=0
                        while ps -p $pid > /dev/null; do
                            [ $cnt -gt 1 ] && sleep 1
                            echo "Sending SIGHUP to process ..." && kill $pid
                            cnt=$(expr $cnt + 1)
                        done
                        [ -e "$pid_path" ] \
                            && (sleep 1 && [ -e "$pid_path" ] \
                            && rm "$pid_path" &)
                        [ -e "$lock_path" ] \
                            && (sleep 1 && [ -e "$lock_path" ] \
                            && rm "$lock_path" &)
                    fi
                fi
                ;;

            status-bg)
                echo -n "Backend node #$i/$num bg process status: "
                run_status=""
                if [ -e "$pid_path" ] \
                && pid_data="$(cat "$pid_path")" \
                && [ -n "$pid_data" ]; then
                    pid="$(echo "$pid_data" \
                        | $SED_E -n 's/.*"pid"[^:]*:[^"]*"([^"]+)".*/\1/p')"
                    if [ -n "$pid" ]; then
                        run_status="PID: $pid"
                        if ps -p $pid > /dev/null; then
                            run_status="$run_status, running"
                        fi
                    fi
                fi
                if [ -z "$run_status" ]; then
                    [ -e "$pid_path" ] \
                        && (sleep 1 && [ -e "$pid_path" ] && rm "$pid_path" &)
                    [ -e "$lock_path" ] \
                        && (sleep 1 && [ -e "$lock_path" ] && rm "$lock_path" &)
                fi
                [ -z "$run_status" ] && run_status="not running"
                echo "$run_status"
                ;;

            setup-sv-configs)
                if [ "$i" == "1" ]; then
                    sv_conf_path="$SUPERVISOR_GENESIS_BE_NODE1_CONF_PATH"
                else
                    sv_conf_path="$(echo "$SUPERVISOR_GENESIS_BE_NODE1_CONF_PATH" \
                        | $SED_E "s/^(.*)(\.conf)\$/\1$i\2/")"
                fi
                get_genesis_be_supervisor_conf $i > "$sv_conf_path"
                update_sv="yes"
                ;;

            update-keys)
                if [ $i -eq 1 ]; then
                    data_dir1="$data_dir/node$i"

                    pr_key1="$([ -r "$data_dir/PrivateKey" ] \
                        && cat "$data_dir/PrivateKey")"
                    host1="127.0.0.1"
                    http_port1=7001
                elif [ $i -gt 1 ]; then
                    echo "Updating keys for backend node #$i/$num ..."
                    pr_key2="$([ -r "$data_dir/PrivateKey" ] \
                        && cat "$data_dir/PrivateKey")"
                    key_id2="$([ -r "$data_dir/KeyID" ] \
                        && cat "$data_dir/KeyID")"
                    pub_key2="$([ -r "$data_dir/PublicKey" ] \
                        && cat "$data_dir/PublicKey")"
                    echo "python3 '$GENESIS_SCRIPTS_DIR/updateKeys.py' '$pr_key1' '$host1' '$http_port1' '$key_id2' '$pub_key2' '100000000000000000000'"
                    python3 "$GENESIS_SCRIPTS_DIR/updateKeys.py" "$pr_key1" "$host1" "$http_port1" "$key_id2" "$pub_key2" "100000000000000000000"
                fi
                ;;

            update-full-nodes)
                hosts[$i]="127.0.0.1"
                http_hosts[$i]="127.0.0.1"
                http_ports[$i]=700$i
                api_urls[$i]="http://${http_hosts[$i]}:${http_ports[$i]}"

                if [ $i -eq 1 ]; then
                    tcp_ports[$i]=7078
                    tcp_addrs[$i]="${hosts[$i]}"
                elif [ $i -gt 1 ]; then
                    tcp_ports[$i]=701$i
                    tcp_addrs[$i]="${hosts[$i]}:${tcp_ports[$i]}"
                fi

                key_ids[$i]="$([ -r "$data_dir/KeyID" ] \
                                && cat "$data_dir/KeyID")"
                pr_keys[$i]="$([ -r "$data_dir/PrivateKey" ] \
                                && cat "$data_dir/PrivateKey")"
                node_pub_keys[$i]="$([ -r "$data_dir/NodePublicKey" ] \
                                && cat "$data_dir/NodePublicKey")"
                ;;

            *)
                echo "Unknown backends set command '$cmd'"
                return 10
                ;;
        esac
    done
    case "$cmd" in
        update-full-nodes)
            node_str="["
            for j in $(seq 1 $num); do
                [ "$node_str" != '[' ] && node_str="${node_str},"
                node_str="${node_str}{\"tcp_address\":\"${tcp_addrs[$j]}\",\"api_address\":\"${api_urls[$j]}\",\"key_id\":\"${key_ids[$j]}\",\"public_key\":\"${node_pub_keys[$j]}\"}"
            done
            node_str="${node_str}]"
            echo "node_str: $node_str"
            python3 "$GENESIS_SCRIPTS_DIR/newValToFullNodes.py" "${pr_keys[1]}" "${http_hosts[1]}" "${http_ports[1]}" $node_str
            ;;

        update-full-nodes-ext)
            $SCRIPT_DIR/fullnodes.sh $num
            ;;

        update-keys-ext)
            $SCRIPT_DIR/upkeys.sh $num
            ;;
    esac
    if [ "$reread_sv" = "yes" ]; then
        supervisorctl reread || return $?
    fi
    if [ "$update_sv" = "yes" ]; then
        supervisorctl update || return $?
    fi
}

setup_frontends() {
    local num; [ -z "$1" ] \
        && echo "The number of frontends isn't set" && return 1 \
        || num=$1
    [ -z "$2" ] && cps=$CLIENT_PORT_SHIFT || cps=$2

    local cnt; cnt=0; local c_port; local s data_dir
    for i in $(seq 1 $1); do
        data_dir="$GENESIS_BE_ROOT_DATA_DIR/node$i"
        chmod go+r "$data_dir/PrivateKey"
        c_port=$(expr $i + $cps)
        if [ $cnt -gt 0 ]; then
            s="$i"
            if [ ! -d /genesis-front/build$i ]; then
                echo "Copying /genesis-front/build to /genesis-front/build$i ..."
                cp -r /genesis-front/build /genesis-front/build$i 
            fi
            sed "s/81/8$i/g" /etc/nginx/sites-available/default > /etc/nginx/sites-available/default$i
            echo "file: /etc/nginx/sites-available/default$i"
            sed -i -e "s/node1/node$i/g" /etc/nginx/sites-available/default$i
            sed -i -e "s/build/build$i/g" /etc/nginx/sites-available/default$i
            sed -i -e "s/access\.log/access$i.log/g" /etc/nginx/sites-available/default$i
            sed -i -e "s/errors\.log/errors$i.log/g" /etc/nginx/sites-available/default$i
        else
            s=""
        fi
        sed -r -i -e "s/(127.0.0.1:)([^\/]+)(\/)/\1$c_port\3/g" /genesis-front/build$s/settings.json
        [ -e /etc/nginx/sites-enabled/default$s ] \
            && rm /etc/nginx/sites-enabled/default$s
        ln -s /etc/nginx/sites-available/default$s /etc/nginx/sites-enabled/default$s
        cnt=$(expr $cnt + 1)
    done
    supervisorctl reread && supervisorctl update && supervisorctl restart nginx
}

import_demo_apps() {
    local key_id pr_key host http_port data_path
    key_id=$([ -r "$GENESIS_BE_ROOT_DATA_DIR/node1/KeyID" ] \
                && cat "$GENESIS_BE_ROOT_DATA_DIR/node1/KeyID")
    pr_key=$([ -r "$GENESIS_BE_ROOT_DATA_DIR/node1/PrivateKey" ] \
                && cat "$GENESIS_BE_ROOT_DATA_DIR/node1/PrivateKey")
    host="127.0.0.1"
    http_port=7001
    data_path="$GENESIS_APPS_DIR/demo_apps.json"

    python3 "$GENESIS_SCRIPTS_DIR/import_demo_apps.py" "$pr_key" "$host" "$http_port" "$data_path"
}

if [ "$0" = "$BASH_SOURCE" ]; then
    case "$1" in 
        create-configs|gen-keys|gen-first-block|init-dbs|start-bg|stop-bg|status-bg|setup-sv-configs|update-keys|update-full-nodes)
            run_genesis_be_set_cmd $@
            ;;

        supervisor-conf)
            get_genesis_be_supervisor_conf $2
            ;;

        setup-frontends)
            setup_frontends $2 $3
            ;;

        import-demo-apps)
            import_demo_apps
            ;;
    esac
fi
