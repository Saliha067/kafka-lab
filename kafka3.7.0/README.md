### step 1: Initialize zookeeper 

```bash
for i in 1 2 3; do \
    echo "Starting zookeeper node zk$i"
    docker exec zk$i bash -c 'echo $ZOO_MY_ID > /zookeeper/data/myid'
    docker exec zk$i bash -c 'echo $ZOO_SERVERS | tr " " "\n" >> /opt/kafka/config/zoo.cfg'
    docker exec zk$i systemctl start zookeeper
done

# Verify zookeeper is running
docker exec zk1 bash -c 'echo ruok | nc localhost 2181'
# Expected output: imok

docker exec zk1 systemctl status zookeeper | grep "Active:"
# Expected output: Active: active (running)
```

### step 2: Initialize kafka brokers

```bash
for i in 1 2 3; do \
    echo "Starting kafka broker node kafka$i"
    docker exec kafka$i bash -c 'sh /var/tmp/kafka_config_generator.sh'
    docker exec kafka$i systemctl start kafka
done

# Verify kafka brokers registered with zookeeper
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
# Expected output: [1, 2, 3]
```

### step 3: verify kafka version

```bash
docker exec kafka1 ls /opt/kafka/libs | grep kafka_
```

### step 4: Create test topic 
```bash
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1.local:9092 --create --topic test --partitions 3 --replication-factor 3

docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1.local:9092 --describe --topic test
```

---

## Upgrade process from 3.7.0 to 3.9.0

### why inter broker protocol version matters?
When upgrading Kafka, brokers need to communicate with each other. During a rolling upgrade:
- Some brokers run 3.7.0, others run 3.9.0
- They need a common protocol to communicate
- inter.broker-protocol version-3.7 ensures compatibility
**Upgrade Rule:** Only update the protocol version AFTER all brokers are on the new version!

---
### Phase 1: Rolling Upgrade to 3.9.0 ( Keep protocol version 3.7 )

Upgrade brokers one at a time while keeping `inter.broker.protocol.version=3.7`

```bash

# Upgrade kafka1
echo "Stopping kafka1..."
docker exec kafka1 systemctl stop kafka
docker stop kafka1
docker rm kafka1

echo "Starting kafka1 with 3.9.0..."
docker run -d \
  --name kafka1 \
  --hostname kafka1.local \
  --network kafka-370.local \
  --privileged \
  -v "$PWD/volumes/kafka1-data:/kafka/logs" \
  -e KAFKA_BROKER_ID=1 \
  -e KAFKA_LISTENERS=PLAINTEXT://kafka1.local:9092 \
  -e KAFKA_ZOOKEEPER_CONNECT=zk1.local:2181,zk2.local:2181,zk3.local:2181 \
  kafka-390-broker:latest

sleep 5
docker exec kafka1 bash -c "sh /var/tmp/kafka_config_generator.sh"
docker exec kafka1 systemctl start kafka

echo "kafka1 upgraded to 3.9.0"

# verify broker is back
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
# Expected output: [1, 2, 3]

# check for under replicated partitions ( should be 0 )
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
--bootstrap-server kafka1.local:9092 --describe --under-replicated-partitions
```

wait for cluster to stabilize ( 1-2 minutes ) , then repear for kafka2:

```bash
# Upgrade kafka2
echo "Stopping kafka2..."
docker exec kafka2 systemctl stop kafka
docker stop kafka2
docker rm kafka2
echo "Starting kafka2 with 3.9.0..."
docker run -d \
  --name kafka2 \
  --hostname kafka2.local \
  --network kafka-370.local \
  --privileged \
  -v "$PWD/volumes/kafka2-data:/kafka/logs" \
  -e KAFKA_BROKER_ID=2 \
  -e KAFKA_LISTENERS=PLAINTEXT://kafka2.local:9092 \
  -e KAFKA_ZOOKEEPER_CONNECT=zk1.local:2181,zk2.local:2181,zk3.local:2181 \
  kafka-390-broker:latest

sleep 5
docker exec kafka2 bash -c "sh /var/tmp/kafka_config_generator.sh"
docker exec kafka2 systemctl start kafka

echo "kafka2 upgraded to 3.9.0"
# verify broker is back
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
# Expected output: [1, 2, 3]
```

wait for cluster to stabilize ( 1-2 minutes ) , then repear for kafka3:

```bash
# Upgrade kafka3
echo "Stopping kafka3..."
docker exec kafka3 systemctl stop kafka
docker stop kafka3
docker rm kafka3
echo "Starting kafka3 with 3.9.0..."
docker run -d \
  --name kafka3 \
  --hostname kafka3.local \
  --network kafka-370.local \
  --privileged \
  -v "$PWD/volumes/kafka3-data:/kafka/logs" \
  -e KAFKA_BROKER_ID=3 \
  -e KAFKA_LISTENERS=PLAINTEXT://kafka3.local:9092 \
  -e KAFKA_ZOOKEEPER_CONNECT=zk1.local:2181,zk2.local:2181,zk3.local:2181 \
  kafka-390-broker:latest

sleep 5
docker exec kafka3 bash -c "sh /var/tmp/kafka_config_generator.sh"
docker exec kafka3 systemctl start kafka

echo "kafka3 upgraded to 3.9.0"
# verify broker is back
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
# Expected output: [1, 2, 3]
```

### Phase 1 Verification

```bash
# All brokers should be running 3.9.0 now
docker exec kafka1 /opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server kafka1.local:9092 | head -3

# Check cluster health
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 --describe --under-replicated-partitions
# Expected: Empty (no under-replicated partitions)

# Verify test topic still works
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 --describe --topic test

# Verify inter.broker.protocol.version is still 3.7
docker exec kafka1 cat /opt/kafka/config/server.properties | grep inter.broker.protocol.version
# Expected: inter.broker.protocol.version=3.7
```

### Phase 2: Update Protocol Version to 3.9

**IMPORTANT:** Only do this AFTER all brokers are running 3.9.0!

```bash
# Update inter.broker.protocol.version on all brokers
for i in 1 2 3; do
  docker exec kafka$i bash -c "
    sed -i 's/inter.broker.protocol.version=3.7/inter.broker.protocol.version=3.9/g' \
    /opt/kafka/config/server.properties
  "
  echo "Updated kafka$i config"
done

# Rolling restart to apply new protocol
for i in 1 2 3; do
  echo "Restarting kafka$i..."
  docker exec kafka$i systemctl restart kafka
  sleep 20
  docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
done
```

### Phase 2 Verification

```bash
# Check cluster is healthy
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 --describe --under-replicated-partitions
# Expected: Empty

# Test produce/consume
echo "test-message" | docker exec -i kafka1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka1.local:9092 --topic test

docker exec kafka1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka1.local:9092 --topic test --from-beginning --max-messages 1
# Expected: test-message
```

## Upgrade Complete!

Your Kafka cluster is now fully upgraded from 3.7.0 to 3.9.0

## Summary of Changes

| Phase | Action | Protocol Version |
|-------|--------|------------------|
| Initial | Kafka 3.7.0 cluster | 3.7 |
| Phase 1 | Rolling upgrade to 3.9.0 | 3.7 (unchanged) |
| Phase 2 | Update protocol version | 3.9 |

---

## Rollback Procedures

### Rollback from Phase 1 (During Upgrade)

If issues occur while upgrading brokers:

```bash
# Stop the upgraded broker
docker stop kafka1
docker rm kafka1

# Start with 3.7.0 image instead
docker run -d \
  --name kafka1 \
  --hostname kafka1.local \
  --network kafka-370.local \
  --privileged \
  -v "$PWD/volumes/kafka1-data:/kafka/logs" \
  -e KAFKA_BROKER_ID=1 \
  -e KAFKA_LISTENERS=PLAINTEXT://kafka1.local:9092 \
  -e KAFKA_ZOOKEEPER_CONNECT=zk1.local:2181,zk2.local:2181,zk3.local:2181 \
  kafka-370-broker:latest

docker exec kafka1 bash -c 'sh /var/tmp/kafka_config_generator.sh'
docker exec kafka1 systemctl start kafka
```

### Rollback from Phase 2 (Protocol Update)

**WARNING:** You CANNOT easily rollback after updating `inter.broker.protocol.version` to 3.9. This is why Phase 2 should only be done after confirming Phase 1 is stable.

---

## Troubleshooting

### Under-Replicated Partitions During Upgrade

```bash
# Check under-replicated partitions
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 --describe --under-replicated-partitions

# Wait for replication to complete (usually 1-5 minutes)
# If persists, check broker logs:
docker exec kafka1 tail -50 /kafka/logs/server.log
```

### Broker Not Joining Cluster

```bash
# Check ZooKeeper connection
docker exec kafka1 bash -c 'echo ruok | nc zk1.local 2181'
# Expected: imok

# Check Kafka broker logs for errors:
docker exec kafka1 tail -100 /kafka/logs/server.log 
```


### Systemd Issues

```bash
docker exec kafka$i systemctl daemon-reload
docker exec kafka$i systemctl restart kafka
```

---

## Verification Checklist

| Check | Command | Expected |
|-------|---------|----------|
| All brokers online | `ls /brokers/ids` | `[1, 2, 3]` |
| No under-replicated partitions | `--under-replicated-partitions` | Empty |
| Kafka version | `kafka-broker-api-versions.sh` | 3.9.0 |
| Produce/Consume | Console producer/consumer | Message received |

## Cleanup

```bash
# Stop all containers (including manually created ones during upgrade)
docker stop kafka1 kafka2 kafka3 zk1 zk2 zk3 2>/dev/null
docker rm kafka1 kafka2 kafka3 zk1 zk2 zk3 2>/dev/null

# Remove docker-compose resources
docker-compose down -v

# Remove network
docker network rm kafka-370.local

# Remove local volumes directory (optional - removes all data)
rm -rf volumes/
```
