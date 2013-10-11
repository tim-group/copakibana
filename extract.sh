#! /bin/bash -eu
set -o pipefail

usage() {
	cat <<EOF
Usage: $(basename "$0") [-u username] QUERY-FILE FIELD...

Extract Logstash event data from ElasticSearch in the form of a CSV file.

QUERY-FILE should be a file containing a query command as prepared by Kibana. You can obtain this in Kibana by hovering over the results table (not the histogram!), then clicking the tiny grey eye that appears to the top right of it. The entire command, including the curl and the quoting, should go in the file.

FIELD... is one or more field paths referring to elements of the event JSON relative to the source event of a given hit. The values at these paths will be included in the output. For example, you might specify @timestamp or @fields.eventType. Note that you probably want to use fields of primitve type, rather than ones which are objects. Putting a JSON objects in a CSV field is bound to lead to trouble. Note that the @timestamp field is always included in the output.

-u can be used to specify a username to use when connecting to ElasticSearch. If it is not specified, the current user's username is used.

You will be prompted for your password so that the script can access Kibana.

The CSV file is written to standard output.

Regrettably, the columns in the CSV file will not be in the order specified on the command line. The jgrep tool used in this script appears to destroy the order. Python's json.tool is used to normalise them into alphabetical order (i think).

EOF
}

CURL_USERNAME=$USER
while getopts "u:" flag
do
	case $flag
	in
		u) CURL_USERNAME="$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

[[ $# -ge 2 ]] || { usage; exit 1; }

COMMAND_FILE="$1"
shift
ARGV=("$@")

[[ $(uname) == Linux ]] || echo >&2 "This script works on Linux; it is currently unlikely to work on systems without the GNU tools"
which curl >/dev/null || { echo >&2 "curl must be on the path"; exit 2; }
which jgrep >/dev/null || { echo >&2 "jgrep must be on the path"; exit 2; }
which python >/dev/null || { echo >&2 "python must be on the path"; exit 2; }

JGREP_FILE="$(mktemp -t $(basename "$0" .sh).XXXXXXXXXX)"
trap "rm -rf \"$JGREP_FILE\"" EXIT

sed -r <"$COMMAND_FILE" "s/^(curl) (-XGET)/\1 -u $CURL_USERNAME \2/" \
	| sh -eu \
	| jgrep --start hits.hits -s "_source.@timestamp ${ARGV[*]/#/_source.}" \
	| python -mjson.tool \
	>"$JGREP_FILE"

for_line_starting() {
	echo "/^ +$1/"
}

CLEAR="s/.*//"
STRIP_NEWLINES="s/\n//g"
MATCH_FIELD="^ *\"_source.([^\"]*)\": (.*)$"

START_OBJECT="$(for_line_starting '\{') {$CLEAR; h; b;};"
HOLD_FIELD_NAME="$(for_line_starting '"') {s/$MATCH_FIELD/\"\1\", /; H; b;};"
HOLD_FIELD_VALUE="$(for_line_starting '"') {s/$MATCH_FIELD/\2/; H; b;};"
END_OBJECT="$(for_line_starting '\}') {g; $STRIP_NEWLINES; p;};"
END_OBJECT_AND_QUIT="$(for_line_starting '\}') {g; $STRIP_NEWLINES; p; q;};"

sed -rn <"$JGREP_FILE" "$START_OBJECT $HOLD_FIELD_NAME $END_OBJECT_AND_QUIT"
sed -rn <"$JGREP_FILE" "$START_OBJECT $HOLD_FIELD_VALUE $END_OBJECT"

