### step 1: Build docker images
```bash
./docker-image-build.sh
```

### step 2: start containers with docker-compose
```bash
docker-compose up -d
sleep 10
docker ps
```

### step 3: Initialize zookeeper 

```bash
for i in 1 2 3; do 
    echo "Starting zookeeper node zk$i"
    docker exec zk$i bash -c 'echo $ZOO_MY_ID > /zookeeper/data/myid' 
    docker exec zk$i bash -c 'echo $ZOO_SERVERS | tr " " "\n" >> /opt/kafka/config/zoo.cfg'
    docker exec zk$i systemctl start zookeeper
done

# Verify zookeeper is running
sleep 5
docker exec zk1 bash -c 'echo ruok | nc localhost 2181'
# Expected output: imok

docker exec zk1 systemctl status zookeeper | grep "Active:"
# Expected output: Active: active (running)
```

### step 4: Initialize kafka brokers

```bash
for i in 1 2 3; do \
    echo "Starting kafka broker node kafka$i" && \
    docker exec kafka$i bash -c 'sh /var/tmp/kafka_config_generator.sh' && \
    docker exec kafka$i systemctl start kafka
done

sleep 10

# Verify kafka brokers registered with zookeeper
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 ls /brokers/ids
# Expected output: [1, 2, 3]
```

### step 5: verify kafka version

```bash
docker exec kafka1 ls /opt/kafka/libs | grep kafka_
```

### step 6: Create test topic 
```bash
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1.local:9092 --create --topic test --partitions 3 --replication-factor 3

docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1.local:9092 --describe --topic test
```
**Expected:** Topic "test" with 3 partitions and replication factor 3 and all replicas in ISR.
---

## Migration Phases

### Phase 1: Deploy KRaft Controllers

```bash
# Get cluster ID from ZooKeeper
CLUSTER_ID=$(docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 \
  get /cluster/id 2>&1 | grep '"id"' | sed 's/.*"id":"\([^"]*\)".*/\1/')
echo "Cluster ID: $CLUSTER_ID"

# Start KRaft controllers
for i in 1 2 3; do 
  echo " Starting kraft$i..."
  docker exec -d -e CLUSTER_UUID=$CLUSTER_ID kraft$i /var/tmp/start-kraft.sh
  sleep 5
done

# Verify quorum formed
sleep 20
docker exec kraft1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-controller kraft1:9093 describe --replication --human-readable
```
**Expected:** 3 controllers( 1 leader, 2 followers )

### Phase 2: Enable Migration on Brokers

```bash
# Add migration config
MIGRATION_CONFIG='listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
zookeeper.metadata.migration.enable=true
controller.quorum.bootstrap.servers=kraft1:9093,kraft2:9093,kraft3:9093
controller.listener.names=CONTROLLER'

for i in 1 2 3; do
  docker exec kafka$i bash -c "echo '$MIGRATION_CONFIG' >> /opt/kafka/config/server.properties"
  echo "added migration config to kafka$i"
done

# Rolling restart
for i in 1 2 3; do
  echo "Restarting kafka$i.…."
  docker exec kafka$i systemctl restart kafka
  sleep 20
  echo "kafka$i restarted."
done

# Verify migration completed
sleep 10
docker exec kraft1 grep "Completed migration" /opt/kafka/logs/server.log
```

**Expected:** "Completed migration of metadata from ZooKeeper to KRaft"

### Phase 3: Move Brokers to KRaft Mode

```bash
# Update broker configs
for i in 1 2 3; do
  docker exec kafka$i bash -c "
    sed -i 's/broker.id/node.id/g' /opt/kafka/config/server.properties
    echo 'process.roles=broker' >> /opt/kafka/config/server.properties
    sed -i '/inter.broker.protocol.version/d' /opt/kafka/config/server.properties
    sed -i '/zookeeper.connect/d' /opt/kafka/config/server.properties
    sed -i '/zookeeper.metadata.migration.enable/d' /opt/kafka/config/server.properties
    sed -i '/zookeeper.session.timeout.ms/d' /opt/kafka/config/server.properties
  "
done

# Rolling restart
for i in 1 2 3; do
  docker exec kafka$i systemctl restart kafka
  sleep 20
done

# Verify
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 --describe --under-replicated-partitions
# Expected: Empty (no under-replicated partitions)
```

# Verify brokers are Oberservers
```bash
docker exec kraft1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-controller kraft1:9093 describe --status
```

**Expected:** 
```
ClusterId:              SnA2-fqPTM-_QGpKAiA8oA
LeaderId:               101
LeaderEpoch:            3
HighWatermark:          1853
MaxFollowerLag:         0
MaxFollowerLagTimeMs:   0
CurrentVoters:          [{"id": 101, "directoryId": "KfL1aMqPSuGz1bX2cY3dEQ", "endpoints": ["CONTROLLER://kraft1:9093"]}, {"id": 102, "directoryId": "GhI2bNrQTvHz2cY3dZ4eFg", "endpoints": ["CONTROLLER://kraft2:9093"]}, {"id": 103, "directoryId": "JkL3c0sRUwIa3dZ4eA5fGg", "endpoints": ["CONTROLLER://kraft3:9093"]}]
CurrentObservers:       [{"id": 2, "directoryId": "IEpkgBT6ucGSzwaZm53U-g"}, {"id": 3, "directoryId": "UlEhjluFhWjj5EnHeMD4-g"}, {"id": 1, "directoryId": "S6hsGkwXxgwPaz8JQTzFCQ"}]
```

### Phase 4: Finalize Migration
```bash
# Remove ZK config from controllers
for i in 1 2 3; do
  docker exec kraft$i bash -c "
    sed -i '/zookeeper.connect/d' /opt/kafka/config/kraft/controller.properties
    sed -i '/zookeeper.metadata.migration.enable/d' /opt/kafka/config/kraft/controller.properties
  "
done

# Rolling restart controllers
for i in 1 2 3; do
  docker exec kraft$i pkill -f kafka
  sleep 3
  docker exec -d -e CLUSTER_UUID=$CLUSTER_ID kraft$i /var/tmp/start-kraft.sh
  sleep 15
  echo "kraft$i restarted."
done

echo "Migration completed! ZooKeeper can now be decommissioned."
```

### Decommission ZooKeeper

```bash
# Stop ZooKeeper services
for i in 1 2 3; do
  echo "Stopping zookeeper node zk$i"
  docker exec zk$i systemctl stop zookeeper 2>/dev/null || docker exec zk$i pkill -f zookeeper
  sleep 2
done

# Verify ZooKeeper is stopped
for i in 1 2 3; do
  STATUS=$(docker exec zk$i ps aux | grep -E "zookeeper|QuorumPeerMain" | grep -v grep || echo "No ZooKeeper process")
  echo "zk$i: $STATUS"
done

echo "ZooKeeper services stopped successfully."
echo ""
echo "Optional: Stop ZooKeeper containers entirely (recommended after validating Kafka cluster)"
echo "Run: docker stop zk1 zk2 zk3"
```

### Verify final quorum status

```bash
docker exec kraft1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-controller kraft1:9093 describe --replication --human-readable
```

**Expected:** 
```
NodeId  DirectoryId             LogEndOffset    Lag     LastFetchTimestamp      LastCaughtUpTimestamp  Status  
101     KfL1aMqPSuGz1bX2cY3dEQ  2718            0       6 ms ago                6 ms ago               Leader  
102     GhI2bNrQTvHz2cY3dZ4eFg  2718            0       226 ms ago              226 ms ago             Follower
103     JkL3c0sRUwIa3dZ4eA5fGg  2718            0       226 ms ago              226 ms ago             Follower
2       IEpkgBT6ucGSzwaZm53U-g  2718            0       226 ms ago              226 ms ago             Observer
3       UlEhjluFhWjj5EnHeMD4-g  2718            0       226 ms ago              226 ms ago             Observer
1       S6hsGkwXxgwPaz8JQTzFCQ  2718            0       226 ms ago              226 ms ago             Observer
```

### Test producer/consumer

```bash
# Create test topic
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka1.local:9092 \
  --create --topic migration-test --partitions 1 --replication-factor 3

sleep 2

# Produce message
docker exec kafka1 bash -c 'echo "hello-kraft" | /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka1.local:9092 --topic migration-test'

echo "Message produced"

# Consume message
docker exec kafka1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka1.local:9092 --topic migration-test \
  --from-beginning --max-messages 1 --property print.timestamp=true
```

## Verification Summary

| Phase | Check | Command | Expected |
|-------|-------|---------|----------|
| Phase 1 | Quorum formed | `kafka-metadata-quorum.sh describe --replication --human-readable` | 1 Leader, 2 Followers |
| Phase 2 | Migration completed | `grep "Completed migration" /opt/kafka/logs/server.log` | Log entry found |
| Phase 2 | No under-replicated | `kafka-topics.sh --describe --under-replicated-partitions` | Empty output |
| Phase 3 | Brokers as Observers | `kafka-metadata-quorum.sh describe --status` | 3 Voters, 3 Observers |
| Phase 4 | Producer/Consumer | Test message flow | Message received |

---

## Rollback Procedures

### Rollback from Phase 1

```bash
for i in 1 2 3; do docker exec kraft$i pkill -f kafka; done
```

### Rollback from Phase 2

```bash
# Stop controllers
for i in 1 2 3; do docker exec kraft$i pkill -f kafka; done

# Remove ZK migration znodes
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 deleteall /controller
docker exec zk1 /opt/kafka/bin/zookeeper-shell.sh localhost:2181 deleteall /migration

# Remove migration config from brokers
for i in 1 2 3; do
  docker exec kafka$i bash -c "
    sed -i '/listener.security.protocol.map/d' /opt/kafka/config/server.properties
    sed -i '/zookeeper.metadata.migration.enable/d' /opt/kafka/config/server.properties
    sed -i '/controller.quorum.bootstrap.servers/d' /opt/kafka/config/server.properties
    sed -i '/controller.listener.names/d' /opt/kafka/config/server.properties
  "
done

# Rolling restart
for i in 1 2 3; do docker exec kafka$i systemctl restart kafka; sleep 20; done
```

### Rollback from Phase 3

```bash
# Revert broker configs to ZK mode
for i in 1 2 3; do
  docker exec kafka$i bash -c "
    sed -i 's/node.id/broker.id/g' /opt/kafka/config/server.properties
    sed -i '/process.roles/d' /opt/kafka/config/server.properties
    echo 'zookeeper.connect=zk1.local:2181,zk2.local:2181,zk3.local:2181' >> /opt/kafka/config/server.properties
    echo 'zookeeper.metadata.migration.enable=true' >> /opt/kafka/config/server.properties
  "
done

# Rolling restart
for i in 1 2 3; do docker exec kafka$i systemctl restart kafka; sleep 20; done

# Then follow Phase 2 rollback
```

---

## Production Mitigations

These settings are applied BEFORE migration to prevent issues:

| Setting | Value | Reason |
|---------|-------|--------|
| `auto.leader.rebalance.enable` | false | Prevents PLE during rolling restart (causes timeouts in production) |
| `unclean.leader.election.enable` | false | Data safety |

### Issue: Application Timeouts During Phase 2/3

**Root Cause:** Preferred Leader Election (PLE) coinciding with broker rolling restart causes high `LeaderAndIsr` request load.

**Mitigation:** Set `auto.leader.rebalance.enable=false` on ALL brokers BEFORE starting migration.

### Issue: OutOfOrderSequenceException

**Root Cause:** Non-default producer `retries` setting.

**Mitigation:** Use default retry settings in Kafka producer applications.

---

## Cleanup

```bash
docker-compose down -v
docker rmi kafka-lab-base kafka-lab-zk kafka-lab-kafka kafka-lab-kraft
```
---
