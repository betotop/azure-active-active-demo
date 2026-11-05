.PHONY: preflight deploy status chaos verify start stop destroy seed web cdc push smoke diagram
preflight: ; ./scripts/preflight.sh
deploy:    ; ./scripts/deploy.sh
status:    ; ./scripts/status.sh
verify:    ; ./scripts/verify-sync.sh
smoke:     ; ./scripts/smoke-test.sh
seed:      ; ./scripts/seed.sh A 6
web:       ; ./scripts/deploy-web.sh
cdc:       ; ./scripts/configure-cdc.sh A && ./scripts/configure-cdc.sh B
push:      ; ./scripts/push-bundle.sh A && ./scripts/push-bundle.sh B
start:     ; ./scripts/start.sh
stop:      ; ./scripts/stop.sh
destroy:   ; ./scripts/destroy.sh
