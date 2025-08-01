#!/bin/sh
#
# Base system installer

# Dynamic values to be defaults in installer prompts; name as .env key+'_default'

# All IPs connected to the system, de-duplicated, space-separated
whitelisted_hosts_default=$(who | awk '{print $NF}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ')

# Hijack certain prompts
_system_prompt_server_ip() (
    _prompt=$1 # shorthand to prompt text
    _defaults=$2 # shorthand to default value(s)
    _help=$3 # shorthand to help text
    shift 3 # drop first 3 args
    _defaults=$(_get_public_ip)
    _provided_ip=$(_input 'server_ip' "$_prompt" "$_defaults" "$_help" "$@")
    if ! { echo "$_provided_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }; then
        echo "${_provided_ip} does not look like a valid IPv4 address" >&2
        _system_prompt_server_ip "$_prompt" "$_defaults" "$_help" "$@"
    fi
    ping -c 1 "${_provided_ip}">/dev/null 2>&1
    if [ "$?" -gt "0" ]; then
        echo "${_provided_ip} is not connectable." >&2
        _system_prompt_server_ip "$_prompt" "$_defaults" "$_help" "$@"
        return
    fi
    printf '%s' "$_provided_ip"
)
_system_prompt_ssh_pubkey() (
    _prompt_text=$1 # shorthand to prompt text
    _defaults=$2 # shorthand to default value(s); not used here
    _help=$3 # shorthand to help text
    shift 3 # drop first 3 args
    _provided_pubkey=$(_input 'ssh_pubkey' "$_prompt_text" '' "$_help" "$@")
    # Make sure the provided public key is valid
    printf "$_provided_pubkey" | ssh-keygen -l -f - > /dev/null
    if [ $? -ne 0 ]; then
        printf "The public key you provided is not valid.\n" >&2
        _system_prompt_ssh_pubkey "$_prompt_text" '' "$_help" "$@"
        return
    fi
    printf '%s' "$_provided_pubkey"
)

_system_pre_install_debian() {
    _package install apt-transport-https
    _package install ca-certificates
    _package install lsb-release
    _package install gnupg
    # Update sources.list
    _debian_codename=$(lsb_release -sc)
    cat /dev/null > /etc/apt/sources.list
    echo "deb http://httpredir.debian.org/debian ${_debian_codename} main contrib non-free" >> /etc/apt/sources.list
    echo "deb http://httpredir.debian.org/debian ${_debian_codename}-backports main contrib non-free" >> /etc/apt/sources.list
    echo "deb http://security.debian.org/ ${_debian_codename}/updates main contrib non-free" >> /etc/apt/sources.list
    for k in $(apt-get update 2>&1|grep -o NO_PUBKEY.*|sed 's/NO_PUBKEY //g');do echo "key: $k";gpg --recv-keys $k;gpg --recv-keys $k;gpg --armor --export $k|apt-key add -;done
    _package install debian-archive-keyring
    apt-get update
    # Restore iptables rules on boot
    mkdir -p /etc/iptables-bonjour
    cat > /etc/iptables-bonjour/README <<-'EOF'
	Iptables rules stored in individual .sh files and managed by bonjour-sh.
	Each .sh file contains a simple `iptables ...` command. Shebang is optional.
	The rules are restored by /etc/network/if-up.d/iptables-bonjour on boot.
	EOF
    # EOF above must be indented with 1 tab character
    cat > /etc/network/if-up.d/iptables-bonjour <<-'EOF'
	#!/bin/sh
	[ -f "/run/iptables-bonjour.lock" ] && exit 0
	touch "/run/iptables-bonjour.lock"
	chmod +x /etc/iptables-bonjour/*.sh
	for file in /etc/iptables-bonjour/*.sh; do
	    [ -f "$file" ] || continue # catch literal '/etc/iptables-bonjour/*.sh'
	    sh "$file"
	done
	EOF
    # EOF above must be indented with 1 tab character
    chmod +x /etc/network/if-up.d/iptables-bonjour
    # For systems where ifup is not present
    if ! command -v ifup >/dev/null 2>&1; then
        _generate_rcd 'iptables-bonjour' '/etc/network/if-up.d/iptables-bonjour' ':'
        _at_boot enable 'iptables-bonjour' # schedule above init script at boot
    fi

}

_system_pre_install_freebsd() (
    _at_boot enable ntpd true
    sysrc ntpd_sync_on_start=YES
    # Create basic pf config allowing all traffic (matching Debian's default)
    cat > /etc/pf.conf <<-EOF
	set skip on lo
	pass in all
	pass out all
	EOF
    # EOF above must be indented with 1 tab character
    _at_boot enable pf true
    # Individual configs for specific services will go here
    mkdir -p /etc/pf
    # Configure pf for fail2ban
    _insert_once 'include "/etc/pf/f2b.conf"' '/etc/pf.conf'
    cat > '/etc/pf/f2b.conf' <<-EOF
	anchor "f2b/*"
	table <f2b> persist
	block in quick from <f2b> to any
	EOF
    # EOF above must be indented with 1 tab character
    pfctl -f /etc/pf.conf
)

_system_pre_install() {
    
    # at >> /root/.bash_profile
    _package install screen
}

_system_install_debian() {
    _package purge man-db # speed up apt-get on machines with slow I/O
    _package install build-essential
    _package install apt-utils
    _package install make
    _package install sed
    _package install cron
    _package install vim
    _package install tzdata
    _package install net-tools # provides netstat
    _package install netcat # provides nc
    _package install python3-gi # fix "Unable to monitor PrepareForShutdown() signal"
    _is_systemd_system && _package install python3-systemd # fix fail2ban backend failed to initialize no module named systemd
}

_system_install() {
    # Clean up to get a minimal install
    _package purge exim4
    _package purge nginx
    _package purge apache2
    _package purge proftpd
    _package purge exim4
    _package purge postfix
    _package purge postgrey
    _package purge sendmail
    _package purge dovecot
    _package purge mariadb
    _package purge mysql
    # Install system tools
    _package install sudo
    _package install coreutils
    _package install curl
    _package install wget
    _package install easy-rsa
    _package install logrotate
    _package install whois
    _package install git
    _package install unzip
    _package install fail2ban
    # Tools used to run backups
    _package install rsync
    _package install rsnapshot
    # Ensure .ssh folder with authorized_keys exists
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/authorized_keys"
    chmod 600 "${HOME}/.ssh/authorized_keys"
    # Create root SSH key if needed
    if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
        ssh-keygen -b 8192 -t rsa -q -f "${HOME}/.ssh/id_rsa" -N "" -C "$(whoami)@${server_ip}"
    fi
    # Configuring SSH
    _config '/etc/ssh/sshd_config' '#' ' ' <<-EOF
	Port ${ssh_port}        # Update the SSH port
	#AcceptEnv               # Stop accepting client environment variables
	LogLevel VERBOSE         # help.ubuntu.com/community/SSH/OpenSSH/Configuring
	PermitEmptyPasswords no  # Disable empty passwords
	X11Forwarding no         # Disable X11Forwarding
	MaxAuthTries 4           # superuser.com/a/1180018
	# infosec-handbook.eu/blog/wss1-basic-hardening/#s3
	KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
	Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
	MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
	HostKeyAlgorithms ssh-ed25519,rsa-sha2-256,rsa-sha2-512,ssh-rsa-cert-v01@openssh.com
	EOF
    # EOF above must be indented with 1 tab character
    # Restrict SSH to whitelisted hosts
    if [ -n "$whitelisted_hosts" ]; then
        _firewall 'ssh-restrict' flush
        for _whitelisted_host in $whitelisted_hosts; do
            _firewall 'ssh-restrict' allow "$_whitelisted_host" in ":${ssh_port}"
            _firewall 'ssh-restrict' allow ":${ssh_port}" out "$_whitelisted_host"
        done
        _firewall 'ssh-restrict' deny '' in ":${ssh_port}"
        _firewall 'ssh-restrict' deny ":${ssh_port}" out ''
    fi
    if [ -n "$ssh_user" ]; then
        _config '/etc/ssh/sshd_config' '#' ' ' <<-EOF
		PermitRootLogin no     # Disable root login
		AllowUsers ${ssh_user} # Whitelist the non-SSH user
		EOF
        # EOF above must be indented with 2 tab characters
        _dir_home="/home/${ssh_user}"
        # Create $ssh_user inside superuser group
        $(_ useradd) "$ssh_user" -s /bin/sh -md "$_dir_home" -g "$(_ sudo_group)"
        # Ensure .ssh folder with authorized_keys exists
        mkdir -p "${_dir_home}/.ssh"
        chmod 700 "${_dir_home}/.ssh"
        touch "${_dir_home}/.ssh/authorized_keys"
        chmod 600 "${_dir_home}/.ssh/authorized_keys"
        # Create SSH keys for $ssh_user
        if [ ! -f "${_dir_home}/.ssh/id_rsa" ]; then
            ssh-keygen -b 8192 -t rsa -q -f "${_dir_home}/.ssh/id_rsa" -N "" -C "${ssh_user}@${server_ip}"
        fi
        # Ensure correct ownership
        chown -R "$ssh_user" "${_dir_home}/.ssh"
        # Make $ssh_user a sudoer
        echo "${ssh_user} ALL=(ALL) NOPASSWD: ALL" | env EDITOR=tee visudo -f "$(_ local_etc)/sudoers.d/00-${ssh_user}"
    else
        _dir_home="$HOME"
    fi
    # Append public key only if not present yet
    _insert_once "$ssh_pubkey" "${_dir_home}/.ssh/authorized_keys"
    # Generate all missing SSH host keys (RSA, ECDSA, ED25519, etc.)
    # Used to ensure proper SSH host identity on first boot or after system provisioning.
    ssh-keygen -A
    # Default fail2ban configuration for local jails
    cat > "$(_ local_etc)/fail2ban/jail.local" <<-EOF
	[DEFAULT]
	findtime = 1w
	bantime = 1w
	banaction = $(_ fail2ban_banaction)
	banaction_allports = $(_ fail2ban_banaction)
	action = %(action_)s
	ignoreip = ${whitelisted_hosts}
	EOF
    # EOF above must be indented with 1 tab character
    # SSH jail: ban IPs with $maxretry failed logins within $findtime window
    cat > "$(_ local_etc)/fail2ban/jail.d/sshd.local" <<-EOF
	[sshd]
	enabled = true
	mode = aggressive
	port = ${ssh_port}
	filter = sshd
	maxretry = 2
	logpath = %(sshd_log)s
	backend = %(sshd_backend)s
	EOF
    # EOF above must be indented with 1 tab character
    _at_boot enable fail2ban true
}

_system_post_install_debian() {
    # Configure fail2ban on systemd (no /var/log/auth.log) - superuser.com/a/1838559
    _is_systemd_system && _insert_once 'sshd_backend = systemd' /etc/fail2ban/paths-debian.conf
}

_system_post_install() {
    service fail2ban restart
    # Clean up
    _package autoremove
}
