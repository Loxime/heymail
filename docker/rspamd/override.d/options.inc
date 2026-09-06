filters = "dkim";
explicit_modules = [];

disable_hyperscan = true;
disable_monitoring = true;

control_socket = "/var/lib/rspamd/rspamd.sock mode=0600";

dns {
    nameserver = "127.0.0.1";
}
