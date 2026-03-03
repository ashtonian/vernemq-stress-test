#!/usr/bin/env bash
PROFILE_NAME="local"
PROFILE_DESCRIPTION="Docker/local environment (skip host-level networking scenarios)"
PROFILE_FEATURES="balance rebalance tiered_health dead_node_cleanup gossip_tuning reg_trie_workers connection_pool"

declare -gA SCENARIO_COMPAT=(
    [01]="full" [02]="full" [03]="full" [04]="full"
    [05]="full" [06]="full" [07]="full" [08]="full"
    [09]="skip" # network_partition — needs iptables on host network
    [10]="skip" # slow_node — needs tc/netem kernel module
    [11]="skip" # rolling_upgrade — needs per-node image swap
)

PROFILE_POOL_SIZES=(1 4 8)       # smaller set for faster local iteration
PROFILE_WORKER_COUNTS=(1 8 16)
