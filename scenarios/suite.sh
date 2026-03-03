#!/usr/bin/env bash
# suite.sh - Scenario suite selector based on cluster size and version.
#
# Can be sourced (exports select_suite) or run directly:
#   ./suite.sh <cluster_size> [version]
#
# Examples:
#   source suite.sh
#   scenarios=$(select_suite 5 integration)
#
#   ./suite.sh 10 integration   # prints: 01,02,03,04,05,06,07,08,09,10,11

select_suite() {
    local size="$1" version="${2:-integration}"
    case "$size" in
        1) echo "01" ;;
        2|3) echo "01,04,06" ;;
        4) echo "01,03,04,06" ;;
        5|6|7|8|9)
            if [[ "$version" == "integration" ]]; then
                echo "01,02,03,04,05,06"
            else
                echo "01,03,04,05,06"
            fi
            ;;
        *)  # 10+
            echo "01,02,03,04,05,06,07,08,09,10,11"
            ;;
    esac
}

# If sourced, export the function. If run directly, print the suite.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <cluster_size> [version]" >&2
        exit 1
    fi
    select_suite "$@"
else
    export -f select_suite
fi
