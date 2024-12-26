curl --remote-name-all\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/install-update-helm.sh\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/start-k8s.sh\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/stop-k8s.sh\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/update-k8s-repos.sh

chmod +x\
		install-update-helm.sh\
		start-k8s.sh\
		stop-k8s.sh\
		update-k8s-repos.sh
  
