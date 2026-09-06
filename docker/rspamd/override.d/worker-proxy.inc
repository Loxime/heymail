enabled = true;

bind_socket = "*v4:11332";

milter = true;
count = 1;
timeout = 30s;

upstream "local" {
    default = true;
    self_scan = true;
}
