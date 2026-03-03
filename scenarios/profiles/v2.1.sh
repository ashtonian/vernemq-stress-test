#!/usr/bin/env bash
PROFILE_NAME="v2.1"
PROFILE_DESCRIPTION="VerneMQ 2.1 official release"
PROFILE_FEATURES=""

declare -gA SCENARIO_COMPAT=(
    [01]="full" [02]="skip" [03]="full" [04]="full"
    [05]="full" [06]="full" [07]="full" [08]="full"
    [09]="full" [10]="full" [11]="full"
)

PROFILE_POOL_SIZES=(1)
PROFILE_WORKER_COUNTS=(1)
