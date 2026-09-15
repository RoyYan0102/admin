uv sync                               # refresh the venv's quant-* commands

bash quant/infra/linux/system_setup.sh --check   # expect only the shared section: missing, exit 1
bash quant/infra/linux/system_setup.sh           # installs /opt/uv-python, /opt/uv-tools, /opt/nvim-lsp, atuin, lock
bash quant/infra/linux/system_setup.sh --check   # expect exit 0
ls /tmp                                          # no root-owned tmp.* left

bash quant/infra/linux/user_setup.sh --check     # as oim_admin: previews what gets removed
bash quant/infra/linux/user_setup.sh
bash quant/infra/linux/user_setup.sh --check
