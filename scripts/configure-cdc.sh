#!/usr/bin/env bash
# configure-cdc.sh A|B : ejecuta vm/configure.sh dentro de la VM (rol REPLICATION, esquema, publicación, conector, topics).
. "$(dirname "$0")/lib.sh"
require_state
R=$(upper "${1:?uso: configure-cdc.sh A|B}")
c_info "[$R] configurando CDC en $(vm_of "$R")…"
out=$(run_on_vm "$R" "cd /opt/aa && ./configure.sh 2>&1 | tail -n 30")
echo "$out"
case "$out" in *CONFIGURE_OK*) c_ok "[$R] CDC configurado";; *) c_err "[$R] configure.sh no terminó bien"; exit 1;; esac
