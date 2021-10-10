#!/bin/bash
#set -eux

tezos/tezos-node snapshot export .snapshots/$(curl -s 127.0.0.1:8732/chains/main/blocks/head/header | jq '.hash' | xargs).rolling --rolling --block $(curl -s 127.0.0.1:8732/chains/main/blocks/head/header | jq '.hash' | xargs)
