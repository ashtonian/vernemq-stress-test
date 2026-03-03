#!/usr/bin/env bash
PROFILE_NAME="integration"
PROFILE_DESCRIPTION="VerneMQ integration branch (all features)"
PROFILE_FEATURES="balance rebalance tiered_health dead_node_cleanup gossip_tuning reg_trie_workers connection_pool"

declare -gA SCENARIO_COMPAT=(
    [01]="full" [02]="full" [03]="full" [04]="full"
    [05]="full" [06]="full" [07]="full" [08]="full"
    [09]="full" [10]="full" [11]="full"
)

PROFILE_POOL_SIZES=(1 4 8 16)    # test multiple pool sizes (1 = baseline comparator)
PROFILE_WORKER_COUNTS=(1 8 16)   # test multiple worker counts
