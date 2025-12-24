#!/bin/bash

# Script to apply KAFKA_ environment variables to server.properties
# =======================================================================

function updateConfig() {
    key=$1
    value=$2
    file=$3

    # Skip internal kafka environment variables
    if [[ $key == "KAFKA_VERSION" ]] || [[ $key == "KAFKA_HOME" ]] || [[ $key == "KAFKA_DEBUG" ]] \
    || [[ $key == "KAFKA_GC_LOG_OPTS" ]] || [[ $key == "KAFKA_HEAP_OPTS" ]] || [[ $key == "KAFKA_JMX_OPTS" ]] \
    || [[ $key == "KAFKA_LOG4J_OPTS" ]] || [[ $key == "KAFKA_JVM_PERFORMANCE_OPTS" ]] || [[ $key == "KAFKA_LOG" ]] \
    || [[ $key == "KAFKA_OPTS" ]]; 
    then
        echo "$key: not passed"
    else
        # update and add the configuration
        if grep -E -q "^#?$key=" "$file"; then
            sed -r -i "s@^#?$key=.*@$key=$value@g" "$file"
            echo "[Updated] '$key' = '$value'"
        else
            echo "$key=$value" >> "$file"
            echo "[Added] '$key' = '$value'"
        fi
    fi
}

echo "=== Kafka Configuration Generator ==="
echo "Applying environment variables to server.properties"

# Read environment variables and update config
for var in $(env); do
    env_var=$(echo "$var" | cut -d= -f1)

    if [[ $env_var =~ ^KAFKA_ ]]; then
        kafka_name=$(echo "$env_var" | cut -d_ -f2- | tr '[:upper:]' '[:lower:]' | tr _ .)
        updateConfig "$kafka_name" "${!env_var}" "/opt/kafka/config/server.properties"
    fi
done

echo "=== Configuration update complete ==="