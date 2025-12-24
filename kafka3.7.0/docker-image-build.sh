#!/bin/bash

docker build -t kafka-370-base:latest -f Dockerfile.base-370 .
docker build -t kafka-390-base:latest -f Dockerfile.base-390 .

docker build -t kafka-370-zk:latest -f Dockerfile.zookeeper .
docker build -t kafka-370-broker:latest -f Dockerfile.kafka-370 .
docker build -t kafka-390-broker:latest -f Dockerfile.kafka-390 .
