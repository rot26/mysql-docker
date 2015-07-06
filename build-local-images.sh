#!/bin/bash

docker build --tag="rot26/mysql-master-slave:5.5-replica" ./5.5 ;
docker build --tag="rot26/mysql-master-slave:5.6-replica" ./5.6 ;
docker build --tag="rot26/mysql-master-slave:5.7-replica" ./5.7 ;
