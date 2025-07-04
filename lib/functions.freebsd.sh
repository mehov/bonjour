#!/bin/sh
#
# FreeBSD-specific implementation for ./functions.sh

_package() {
    case $1 in
        install)
            # FreeBSD package names can be less straightforward compared to Debian:
            #
            # Debian         | FreeBSD
            # -----------------------------------
            # idn            | libidn
            # fail2ban       | py311-fail2ban
            # mariadb-server | mariadb1011-server
            #
            # This piece guesses a FreeBSD candidate based on a Debian package name
            _pkg_name=$(pkg rquery -g '%n' "*$(echo "$2" | sed 's/-/*-/g')" | awk -v name="$2" '
                {
                    # first prefer exact matches ("nginx" = "nginx")
                    if ($0 == name) {
                        exact = $0
                    # accept the library version ("idn" = "libidn")
                    } else if ($0 == ("lib"name)) {
                        matched = $0
                    # accept package that ends with -name ("certbot" = "py311-certbot")
                    } else if ($0 ~ ("-"name"$")) {
                        suffix = $0
                    }
                    # fallback to first candidate
                    if (NR == 1) {
                        fallback = $0
                    }
                }
                END {
                    if (exact) {print exact; exit}
                    if (matched) {print matched; exit}
                    if (suffix) {print suffix; exit}
                    print fallback
                }
            ')
            pkg install -y -f $_pkg_name
            ;;
        purge)
            pkg delete -y -f $2*
            ;;
        upgrade)
            pkg upgrade -y
            ;;
        autoremove)
            pkg autoremove -y
            ;;
    esac
}

# _at_boot - OS-agnostic wrapper to enable/disable a service at boot
# Depending on ACTION:
# - SERVICE starting up at boot will be enabled or disabled;
# - if ACT_IMMEDIATELY is true, SERVICE will be started or stopped immediately
# Usage: _at_boot ACTION SERVICE ACT_IMMEDIATELY
# Arguments:
#   $1 - ACTION: enable|disable
#   $2 - SERVICE: service name
#   $3 - ACT_IMMEDIATELY: true to start/stop (depending on ACTION) the service now
_at_boot() (
    _status=$( [ "_$1" = "_enable" ] && echo YES || echo NO )
    sysrc "${2}_enable=${_status}"
    if [ "_$3" = "_true" ]; then
        service "$2" $( [ "_$1" = "_enable" ] && echo start || echo stop )
    fi
)

# _firewall - OS-agnostic wrapper to manage firewall
# Usage: _firewall RULE-NAME STATE SRC DIRECTION DST
# Arguments:
#   $1 - RULE-NAME: name for rule(set), used in filename for persisting
#   $2 - STATE: allow|deny|flush
#   $3 - SRC: see DST below
#   $4 - DIRECTION: in|out
#   $5 - DST: IP[/MASK][:PORT], e.g. 1.2.3.4, 1.2.3.4:56, 1.2.3.4/24:56 etc.
_firewall() (
    _file="/etc/pf/bonjour-${1}.conf"
    # Determine action
    case $2 in
        allow)
            _action='pass'
            ;;
        deny)
            _action='block'
            ;;
        flush)
            : > "$_file"
            return
    esac
    # Parse IP[/MASK] and PORT out of SRC and DST
    IFS=':' read -r _src_host _src_port <<-EOF
	$3
	EOF
    IFS=':' read -r _dst_host _dst_port <<-EOF
	$5
	EOF
    # EOFs above must be indented with 1 tab character
    # Build src line
    [ -n "$_src_host" ] || _src_host='any'
    [ -n "$_dst_host" ] || _dst_host='any'
    if [ -n "$_src_port" ]; then
        _src_port="port ${_src_port}"
    fi
    if [ -n "$_dst_port" ]; then
        _dst_port="port ${_dst_port}"
    fi
    $BONJOUR_DEBUG && cat >&2 <<-EOF
	    @          $@
	    file       $_file
	    action     $_action
	    direction  $4
	    src
	        host   $_src_host
	        port   $_src_port
	    dst
	        host   $_dst_host
	        port   $_dst_port
	EOF
    # EOF above must be indented with 1 tab character
    _rule="${_action} ${4} on egress proto tcp from ${_src_host} ${_src_port} to ${_dst_host} ${_dst_port}"
    _insert_once "$_rule" "$_file"
    _insert_once "include \"$_file\"" "/etc/pf.conf"
)
