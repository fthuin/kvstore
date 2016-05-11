#!/bin/bash
chmod +x dev/dev*/bin/kvstore
chmod +x dev/dev*/bin/kvstore-admin
for d in dev/dev*; do $d/bin/kvstore start; done
for d in dev/dev*; do $d/bin/kvstore ping; done
./dev/dev2/bin/kvstore-admin join kvstore1@127.0.0.1
./dev/dev3/bin/kvstore-admin join kvstore1@127.0.0.1
echo 'Nodes 2,3 joined on 1'
