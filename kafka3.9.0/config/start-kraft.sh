#!/bin/bash -e

KAFKA_HOME=/opt/kafka
KRAFT_CONFIG_PATH=$KAFKA_HOME/config/kraft
CONFIG=$KRAFT_CONFIG_PATH/controller.properties
EXCLUSIONS="|KAFKA_VERSION|KAFKA_HOME|KAFKA_DEBUG|KAFKA_GC_LOG_OPTS|KAFKA_HEAP_OPTS|KAFKA_JMX_OPTS|KAFKA_LOG4J_OPTS|KAFKA_JVM_PERFORMANCE_OPTS|KAFKA_LOG|KAFKA_OPTS|"

config_updater() {
    echo "==> Applying environment variables..."
    for VAR in $(env)
    do
        env_var=$(echo "$VAR" | cut -d= -f1)
        if [[ "$EXCLUSIONS" = *"|$env_var|"* ]]; then
            continue
        fi

        if [[ "$env_var" =~ ^KAFKA_ ]]; then
            kafka_name=$(echo "$env_var" | cut -d_ -f2- | tr '[:upper:]' '[:lower:]' | tr _ .)
            if grep -E -q "^#?$kafka_name=" "$CONFIG"; then
                sed -r -i "s@^#?$kafka_name=.*@$kafka_name=${!env_var}@g" "$CONFIG"
            else
                echo "$kafka_name=${!env_var}" >> $CONFIG
            fi
        fi
    done
    echo "=> Environment variables applied."
}

setup_kafka_storage() {
    echo ""
    echo "==> Kafka storage setup."
    echo "INITIAL_CONTROLLERS: $INITIAL_CONTROLLERS"
    echo "CLUSTER_UUID: $CLUSTER_UUID"
    $KAFKA_HOME/bin/kafka-storage.sh format \
        --cluster-id $CLUSTER_UUID \
        --config $CONFIG \
        --initial-controllers "$INITIAL_CONTROLLERS" \
        --ignore-formatted \
        --feature kraft.version=1
    echo "==> Kafka storage setup completed."
}

start_kafka() {
    echo ""
    echo "==> Starting kafka controller process."
    exec "$KAFKA_HOME/bin/kafka-server-start.sh" $CONFIG
}

echo "==> This container's role is controller"
config_updater
setup_kafka_storage
start_kafka
