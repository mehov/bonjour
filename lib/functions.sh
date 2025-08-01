#!/bin/sh
#
# Reusable functions

# Dictionary function, resolves os-specific value for passed key
_() (
    if [ ! -f "${BONJOUR_DIR}/.${BONJOUR_OS}.env" ]; then
        echo "Dictionary file .${BONJOUR_OS}.env not found in ${BONJOUR_DIR}" >&2
    fi
    . "${BONJOUR_DIR}/.${BONJOUR_OS}.env"
    eval "printf '%s' \"\${$1}\""
)

_is_systemd_system() (
    # freedesktop.org/software/systemd/man/latest/sd_booted.html
    [ -d "/run/systemd/system" ] && return 0
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && return 0
    return 1
)

_input() (
    _name=$1 # shorthand to the name of requested variable
    _prompt_text=$2 # shorthand to the prompt text
    _defaults=$3 # shorthand to the default value(s)
    _help=$4 # shorthand to help text; pass empty '' if not needed
    shift 4 # drop first 4 args so that we don't loop through them below
    # Determine the prompt type: text input, boolean yes/no, multiple choice
    _type='text' # assume plain text by default
    if [ "$_defaults" = true ] || [ "$_defaults" = false ]; then
        _type='boolean' # update to boolean
    fi
    # Check if $_defaults is a space-separated list of words,
    # where each word consists only of lowercase letters and digits.
    if printf '%s\n' "$_defaults" | grep -q '^[a-z0-9._-]\{1,\}\( [a-z0-9._-]\{1,\}\)\{1,\}$'; then
        _type='select' # update to multiple choice
    fi
    $BONJOUR_DEBUG && cat >&2 <<-EOF
	
	<_input>
	    _name        $_name
	    _prompt_text $_prompt_text
	    _defaults    $_defaults
	    _help        $_help
	    _type        $_type
	EOF
    # EOF above must be indented with 1 tab character
    _value='' # default to empty
    # Loop through (remaining) arguments and/or flags passed to the script
    for _arg in "$@"; do
        _key="${_arg%%=*}" # parse --KEY out of --KEY=VALUE
        if [ "$_key" != "--$_name" ]; then # skip keys that don't match
            continue
        fi
        if [ "$_arg" = "--$_name" ]; then # if we only received --KEY
            _value="$_defaults" # we're explicitly told to use default value
        else
            _value="${_arg#*=}" # parse VALUE out of --KEY=VALUE
        fi
        $BONJOUR_DEBUG && cat >&2 <<-EOF
		    ----
		    $@
		    ----
		    _arg   $_arg
		    _key   $_key
		    _value $_value
		EOF
        # EOF above must be indented with 2 tab characters
        if [ -z "$_value" ]; then # this flag was provided with no value
            if [ 'boolean' = $_type ]; then
                _value=true # for booleans, consider no value as a yes
            else
                _value="$_defaults" # otherwise, use whatever is the default
                _prompt_text="" # emptying prompt makes sure it's not shown
            fi
            $BONJOUR_DEBUG && echo " -> $_value" >&2
        fi
        break
        unset -v _arg _key
    done
    # If value was not found in arguments, and prompt is configured, do prompt
    if [ "$BONJOUR_NONINTERACTIVE" != "true" ] && [ -n "$_prompt_text" ] && [ -z "$_value" ]; then
        # Format defaults displayed after prompt text
        if [ 'boolean' = $_type ]; then # if expecting boolean, format as Y/N
            _prompt_defaults=$("$_defaults" && echo "Y/n" || echo "y/N")
        else # display literally
            _prompt_defaults="$_defaults"
        fi
        # Wrap in square brackets
        if [ ! -z "$_prompt_defaults" ]; then
            _prompt_defaults=" [$_prompt_defaults]"
        fi
        # Indicate when help is available
        if [ ! -z "$_help" ]; then
            _prompt_defaults="${_prompt_defaults} / (?)"
        fi
        # Finally, prompt
        printf "${_prompt_text}${_prompt_defaults}: " >&2
        read _value < /dev/tty
    fi
    # Output help text if user asked for it
    if [ "_${_value}" = "_?" ] && [ ! -z "$_help" ]; then
        printf "\n\n${_name}:\n${_help}\n" >&2
        _input "$_name" "$_prompt_text" "$_defaults" "$_help" "$@"
        return 0 # prevent debugging nested _input calls
    fi
    $BONJOUR_DEBUG && printf '    _value "%s"' "$_value" >&2
    # Assume the defaults if $_value is still empty at this point
    if [ -z "$_value" ]; then
        _value="$_defaults"
    fi
    # For boolean prompts, ensure $_value is boolean
    if [ 'boolean' = $_type ]; then
        case "$_value" in
            [Yy]) _value=true ;;
            [Nn]) _value=false ;;
        esac
    fi
    $BONJOUR_DEBUG && printf ' -> "%s"\n</_input>\n\n' "$_value" >&2
    # Return the value
    printf '%s' "$_value"
    # Clean up
    unset -v _name _prompt_text _defaults _type _value _prompt_defaults _help
)

_get_public_ip() (
    _url='http://checkip.amazonaws.com/'
    if command -v curl >/dev/null 2>&1; then
        curl -s "$_url"
        exit
    fi
    if command -v fetch >/dev/null 2>&1; then
        fetch -qo - "$_url"
        exit
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "$_url"
        exit
    fi
    echo 'Error: curl, fetch, or wget not found.' >&2
    exit 1
)

# _insert_once - insert line into file, checking if it exists before inserting
# Usage: _insert_once LINE FILE or _insert_once FILE <<EOF\nLINE(1..n)\nEOF
# Arguments when using 2 arguments:
#   $1 - LINE: full line without trailing \n
#   $2 - FILE: path to file where LINE should be present
# Arguments when using 1 argument:
#   $1 - FILE: path to file where LINEs should be present
#   heredoc to function stdin - LINE1, LINE2, LINEn: full lines separated by \n
_insert_once() {
    # If received 1 argument, that should be the file path and input is heredoc
    if [ $# -eq 1 ]; then
        while IFS= read -r _l; do # loop through each line in stdin
            _insert_once "$_l" "$1" # call self recursively for current line
        done
        return # return early
    fi
    # If received 2 arguments, see if the value contains literal `\n`
    case "$1" in
        *\\n*) # value contains literal backslash character followed by n
            # Call self via heredoc converting literal `\n` into new line
            _insert_once "$2" <<-EOF
			$(printf "%s" "$1" | sed 's/\\n/\n/g')
			EOF
            return $? # return early
            ;;
    esac
    # At this point we can treat the value in $1 as one plain line
    # Make sure the file exists
    [ -f "$2" ] || touch "$2"
    # Check if the line already exists in the file; if not, append it
    grep -qxF "$1" "$2" || printf '%s\n' "$1" >> "$2"
}

_config() (
    _f=$1 # file path
    _c=$2 # comment character, e.g. `#` or `;`
    _a=$3 # assignment character, e.g. `=` or ` `
    _k=$4 # key to set
    _v=$5 # value to set; if not present, the key will be commented out
    # Create the file if it doesn't exist
    if [ ! -f "$_f" ]; then
        : > "$_f"
    fi
    # 3 arguments: keys and values are passed as heredoc; parse stdin
    if [ $# -eq 3 ]; then
        while IFS= read -r _l; do
            # Remove trailing inline comments
            _l=$(printf '%s\n' "$_l" | sed "s/[[:space:]]\{1,\}${_c}.*$//")
            # Skip blank lines
            [ -z "$_l" ] && continue
            # If line starts with comment character, comment the key out
            if printf '%s\n' "$_l" | grep -q "^${_c}"; then
                _k=$(printf '%s\n' "$_l" | sed "s/^${_c}[[:space:]]*//")
                _config "$_f" "$_c" "$_a" "$_k"
                continue
            fi
            # The line contains `KEY VAL`: call self recursively, set KEY to VAL
            set -- $_l
            _k=$1
            shift
            _v=$*
            _config "$_f" "$_c" "$_a" "$_k" "$_v"
        done
        return
    fi
    # 4+ arguments: keys (and optional values) passed in individual calls
    _match="^[[:space:]]*${_c}*[[:space:]]*${_k}\\(.*\\)$"
    if [ $# -eq 4 ]; then
        # Value not present; commenting out the key
        _replace="${_c}${_k}\1"
    else
        # Setting key to value; escape backslashes to preserve literal `\n`
        _replace="${_k}${_a}$(printf '%s' "$_v" | sed 's/\\/\\\\/g')"
        # If there is a value to set, make sure the key exists in the file
        if ! grep -q "$_match" "$_f"; then
            printf "${_k}\n" >> "$_f" # sed below will set actual value
        fi
    fi
    if sed --version 2>/dev/null | grep -q '^GNU'; then
        sed -i "s|${_match}|${_replace}|" "$_f"
    else
        sed -i '' "s|${_match}|${_replace}|" "$_f"
    fi
)

_certbot_certonly() (
    _non_interactive=; [ "$BONJOUR_NONINTERACTIVE" = 'true' ] && _non_interactive='--non-interactive'
    _port='80'; timeout 2 nc -z 127.0.0.1 80 2>/dev/null && _port='8008'
    _domain='' # placeholder for the main domain name
    _csv='' # comma-separated list of all domains (main + aliases)
    for _d in $1; do
        [ -z "$_domain" ] && _domain="$_d" # first domain is main domain
        [ -n "$_csv" ] && _csv="${_csv},"
        _csv="${_csv}${_d}"
    done
    set -x
    certbot certonly $_non_interactive --agree-tos \
        --standalone --http-01-port "$_port" \
        --email "webmaster@${_domain}" \
        --domains "$_csv"
    _result=$?
    set +x
    exit $_result
)
