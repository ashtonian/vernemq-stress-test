#!/usr/bin/env bash
# suite.sh - Scenario suite selector based on cluster size, version, and category.
#
# Can be sourced (exports select_suite) or run directly:
#   ./suite.sh <cluster_size> [version] [category]
#
# Examples:
#   source suite.sh
#   scenarios=$(select_suite 5 integration all)
#
#   ./suite.sh 10 integration core   # prints: 01,05,06,07,08,09,10,11

# Known scenario categories
CORE_SCENARIOS="01,05,06,07,08,09,10,11"
INTEGRATION_SCENARIOS="02,03,04"

# ---------------------------------------------------------------------------
# Lightweight profile loader for suite filtering (does not require common.sh)
# ---------------------------------------------------------------------------

_suite_profiles_dir="${_suite_profiles_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profiles}"

_suite_load_profile() {
    local version="$1"
    local profile_file=""

    # Exact match
    if [[ -f "${_suite_profiles_dir}/${version}.sh" ]]; then
        profile_file="${_suite_profiles_dir}/${version}.sh"
    else
        local ver="${version#v}"
        local major_minor="${ver%.*}"
        if [[ "$major_minor" != "$ver" && -f "${_suite_profiles_dir}/v${major_minor}.sh" ]]; then
            profile_file="${_suite_profiles_dir}/v${major_minor}.sh"
        else
            local major="${ver%%.*}"
            if [[ -f "${_suite_profiles_dir}/v${major}.x.sh" ]]; then
                profile_file="${_suite_profiles_dir}/v${major}.x.sh"
            fi
        fi
    fi

    if [[ -z "$profile_file" || ! -f "$profile_file" ]]; then
        profile_file="${_suite_profiles_dir}/integration.sh"
    fi

    if [[ -f "$profile_file" ]]; then
        # shellcheck disable=SC1090
        source "$profile_file"
    fi
}

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

filter_by_profile() {
    local scenarios="$1"
    local result=""
    IFS=',' read -ra nums <<< "$scenarios"
    for num in "${nums[@]}"; do
        local compat="${SCENARIO_COMPAT[$num]:-full}"
        if [[ "$compat" != "skip" ]]; then
            result="${result:+$result,}$num"
        fi
    done
    echo "$result"
}

filter_by_category() {
    local scenarios="$1" category="$2"
    if [[ "$category" == "all" ]]; then
        echo "$scenarios"
        return
    fi

    local allowed
    case "$category" in
        core)        allowed="$CORE_SCENARIOS" ;;
        integration) allowed="$INTEGRATION_SCENARIOS" ;;
        *)           echo "$scenarios"; return ;;
    esac

    local result=""
    IFS=',' read -ra nums <<< "$scenarios"
    for num in "${nums[@]}"; do
        if echo ",$allowed," | grep -q ",$num,"; then
            result="${result:+$result,}$num"
        fi
    done
    echo "$result"
}

select_suite() {
    local size="$1" version="${2:-integration}" category="${3:-all}"

    # Load profile for the target version
    _suite_load_profile "$version"

    # Size-based candidate selection
    # Scenarios self-skip via require_min_vmq_nodes if cluster is too small,
    # so including them at a given size is safe.  The ranges below reflect
    # the minimum node requirements documented in each scenario file:
    #   01:1  02:5  03:4  04:2  05:3  06:3  07:5  08:3  09:5  10:3  11:3
    local base
    case "$size" in
        1) base="01" ;;
        2) base="01,04,06" ;;
        3) base="01,04,05,06,08,11" ;;
        4) base="01,03,04,05,06,08,11" ;;
        5|6|7|8|9) base="01,02,03,04,05,06,07,08,09,10,11" ;;
        *) base="01,02,03,04,05,06,07,08,09,10,11" ;;
    esac

    # Filter by profile compatibility, then by category
    base=$(filter_by_profile "$base")
    filter_by_category "$base" "$category"
}

# If sourced, export the functions. If run directly, print the suite.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <cluster_size> [version] [category]" >&2
        exit 1
    fi
    select_suite "$@"
else
    export -f select_suite
    export -f filter_by_category
    export -f filter_by_profile
    export -f _suite_load_profile
fi
