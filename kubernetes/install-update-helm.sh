INSTALL_SCRIPT_PATH=$(mktemp)

echo "Downloading script to $INSTALL_SCRIPT_PATH..."
curl -fsSL -o $INSTALL_SCRIPT_PATH https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

echo "Executing $INSTALL_SCRIPT_PATH..."
chmod 700 $INSTALL_SCRIPT_PATH
$INSTALL_SCRIPT_PATH
