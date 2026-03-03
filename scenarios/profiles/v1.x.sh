#!/usr/bin/env bash
PROFILE_NAME="v1.x"
PROFILE_DESCRIPTION="VerneMQ 1.x official releases"
PROFILE_FEATURES=""

declare -gA SCENARIO_COMPAT=(
    [01]="full" [02]="skip" [03]="full" [04]="skip"
    [05]="full" [06]="full" [07]="full" [08]="full"
    [09]="full" [10]="full" [11]="full"
)

# Scenario 05: pool sizes to test (single = default only)
PROFILE_POOL_SIZES=(1)

# Scenario 04: worker counts to test
PROFILE_WORKER_COUNTS=(1)
