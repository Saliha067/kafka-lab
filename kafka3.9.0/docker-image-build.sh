#!/bin/bash

# build base image ( download kafka 3.9.0 )
docker build -t kraft-lab-base:latest -f Dockerfile.base .

# build service images
docker build -t kraft-lab-zk:latest -f Dockerfile.zookeeper .
docker build -t kraft-lab-kafka:latest -f Dockerfile.kafka .
docker build -t kraft-lab-kraft:latest -f Dockerfile.kraft .