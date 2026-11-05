Lee AGENTS.md y PROMPT.md. Este repositorio despliega una demo activo-activo en Azure con Bicep y scripts bash;
no crees recursos fuera de infra/ ni abras puertos de gestión (22/3389). Para operar las VMs usa `az vm run-command`
a través de scripts/lib.sh. Verifica sintaxis (py_compile, node --check, bash -n, az bicep build) antes de proponer cambios.
