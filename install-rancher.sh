#!/bin/bash -e

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')]: $*"
}

# Function to display spinner
display_spinner() {
  local pid=$1
  local spin='-\|/'

  log "Loading..."

  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spin#?}
    printf "\r [%c]" "$spin"
    local spin=$temp${spin%"$temp"}
    sleep 0.1
  done
  printf "\r"
}

execute_command() {
  local cmd="$*"
  log "Executing: $cmd"
  bash -c "$cmd" &
  display_spinner $!
}

error_exit() {
  log "$1"
  exit 1
}

install_k3s() {
  execute_command "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"v1.26.9+k3s1\" INSTALL_K3S_EXEC=\"--disable traefik\" K3S_KUBECONFIG_MODE=\"644\" sh -s -" || error_exit "Failed to install k3s"
  execute_command "systemctl -q is-active k3s.service" || error_exit "k3s service not active. Exiting..."
}

setup_bash_autocomplete() {
  echo "source <(kubectl completion bash)" >> ~/.bashrc
  source ~/.bashrc
}

setup_environment() {
  cat << EOF | sudo tee /etc/environment
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF
  sudo cat /etc/environment
  source /etc/environment
}

install_nginx() {
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/baremetal/deploy.yaml
}

patch_nginx() {
  cat > ingress.yaml <<EOF
spec:
  template:
    spec:
      hostNetwork: true
EOF
  kubectl patch deployment ingress-nginx-controller -n ingress-nginx --patch "$(cat ingress.yaml)"
}

perform_cluster_check() {
  kubectl cluster-info
  kubectl get nodes
  kubectl describe nodes rancher
  kubectl get pods -A
  kubectl get svc -A -o wide
}

install_git_helm() {
  sudo apt install git
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

helm_autocomplete() {
  echo "source <(helm completion bash)" >> ~/.bashrc
  source ~/.bashrc
}

add_rancher_repo() {
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
  helm repo update
}

generate_certs() {
  openssl genrsa -out rancher.key 2048
  echo 'This part is interactive. Provide proper values.'
  openssl req -new -key rancher.key -out rancher.csr
  openssl x509 -req -days 365 -in rancher.csr -signkey rancher.key -out rancher.crt
}

generate_secret() {
  kubectl -n cattle-system create secret tls tls-rancher-ingress \
  --cert=/home/adrian/rancher.crt \
  --key=/home/adrian/rancher.key
}

generate_values() {
  cat > values.yaml <<EOF
# Additional Trusted CAs.
# Enable this flag and add your CA certs as a secret named tls-ca-additional in the namespace.
# See README.md for details.
additionalTrustedCAs: false
antiAffinity: preferred
topologyKey: kubernetes.io/hostname

# Audit Logs https://rancher.com/docs/rancher/v2.x/en/installation/api-auditing/
# The audit log is piped to the console of the rancher-audit-log container in the rancher pod.
# https://rancher.com/docs/rancher/v2.x/en/installation/api-auditing/
# destination stream to sidecar container console or hostPath volume
# level: Verbosity of logs, 0 to 3. 0 is off 3 is a lot.

auditLog:
  destination: sidecar
  hostPath: /var/log/rancher/audit/
  level: 0
  maxAge: 1
  maxBackup: 1
  maxSize: 100


  # Image for collecting rancher audit logs.
  # Important: update pkg/image/export/resolve.go when this default image is changed, so that it's reflected accordingly in rancher-images.txt generated for air-gapped setups.

  image:
    repository: "rancher/mirrored-bci-micro"
    tag: 15.4.14.3
    # Override imagePullPolicy image
    # options: Always, Never, IfNotPresent
    pullPolicy: "IfNotPresent"


# As of Rancher v2.5.0 this flag is deprecated and must be set to 'true' in order for Rancher to start
addLocal: "true"

# Add debug flag to Rancher server
debug: false

# When starting Rancher for the first time, bootstrap the admin as restricted-admin
restrictedAdmin: false

# Extra environment variables passed to the rancher pods.
# extraEnv:
# - name: CATTLE_TLS_MIN_VERSION
#   value: "1.0"


# Fully qualified name to reach your Rancher server
hostname: rancher.local


## Optional array of imagePullSecrets containing private registry credentials
## Ref: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
imagePullSecrets: []

# - name: secretName

### ingress ###

# Readme for details and instruction on adding tls secrets.
ingress:
  # If set to false, ingress will not be created
  # Defaults to true
  # options: true, false
  enabled: true
  includeDefaultExtraAnnotations: true
  extraAnnotations: {}
  ingressClassName: "nginx"
  # backend port number
  servicePort: 80

  # configurationSnippet - Add additional Nginx configuration. This example statically sets a header on the ingress.
  # configurationSnippet: |
  #   more_set_input_headers "X-Forwarded-Host: {{ .Values.hostname }}";

  tls:
    # options: rancher, letsEncrypt, secret
    source: secret
    secretName: tls-rancher-ingress


### service ###
# Override to use NodePort or LoadBalancer service type - default is ClusterIP

service:
  type: ""
  annotations: {}


### LetsEncrypt config ###
# ProTip: The production environment only allows you to register a name 5 times a week.
#         Use staging until you have your config right.

letsEncrypt:
  # email: none@example.com
  environment: production
  ingress:
    # options: traefik, nginx
    class: "nginx"

# If you are using certs signed by a private CA set to 'true' and set the 'tls-ca'
# in the 'rancher-system' namespace. See the README.md for details
privateCA: false

# http[s] proxy server passed into rancher server.
# proxy: http://example.local:1080

# comma separated list of domains or ip addresses that will not use the proxy
noProxy: 127.0.0.0/8,10.42.0.0/16,10.43.0.0/16,192.168.0.1/24,10.10.0.0/24,rancher.local

# Override rancher image location for Air Gap installs
rancherImage: rancher/rancher

# rancher/rancher image tag. https://hub.docker.com/r/rancher/rancher/tags/
# Defaults to .Chart.appVersion
# rancherImageTag: v2.0.7

# Override imagePullPolicy for rancher server images
# options: Always, Never, IfNotPresent
# Defaults to IfNotPresent
# rancherImagePullPolicy: <pullPolicy>

# Number of Rancher server replicas. Setting to negative number will dynamically between 0 and the abs(replicas) based on available nodes.
# of available nodes in the cluster
replicas: 3

# Set priorityClassName to avoid eviction
priorityClassName: rancher-critical

# Set pod resource requests/limits for Rancher.
resources: {}

#
# tls
#   Where to offload the TLS/SSL encryption
# - ingress (default)
# - external
tls: ingress

systemDefaultRegistry: ""

# Set to use the packaged system charts
useBundledSystemChart: false

# Certmanager version compatibility
certmanager:
  version: ""

# Rancher custom logos persistence
customLogos:
  enabled: false
  volumeSubpaths:
    emberUi: "ember"
    vueUi: "vue"

  ## Volume kind to use for persistence: persistentVolumeClaim, configMap
  volumeKind: persistentVolumeClaim
  ## Use an existing volume. Custom logos should be copied to the volume by the user
  # volumeName: custom-logos
  ## Just for volumeKind: persistentVolumeClaim
  ## To disables dynamic provisioning, set storageClass: "" or storageClass: "-"
  # storageClass: "-"
  accessMode: ReadWriteOnce
  size: 1Gi


# Rancher post-delete hook
postDelete:
  enabled: true
  image:
    repository: rancher/shell
    tag: v0.1.20

  namespaceList:
    - cattle-fleet-system
    - cattle-system
    - rancher-operator-system

  # Number of seconds to wait for an app to be uninstalled
  timeout: 120

  # by default, the job will fail if it fail to uninstall any of the apps
  ignoreTimeoutError: false

# Set a bootstrap password. If leave empty, a random password will be generated.
bootstrapPassword: "test1234"

livenessProbe:
  initialDelaySeconds: 60
  periodSeconds: 30

readinessProbe:
  initialDelaySeconds: 5
  periodSeconds: 30


global:
  cattle:
    psp:
      # will default to true on 1.24 and below, and false for 1.25 and above
      # can be changed manually to true or false to bypass version checks and force that option
      enabled: ""
EOF
}

main() {
  if install_k3s; then
    echo 'k3s is running...'
    setup_bash_autocomplete
    setup_environment
    install_nginx
    patch_nginx
    perform_cluster_check
    install_git_helm
    helm_autocomplete
    add_rancher_repo
    generate_certs
    generate_values
    kubectl create namespace cattle-system
    generate_secret

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo 'Wait 30 seconds...'
    sleep 30 & # Background sleep command
    display_spinner $! # Pass the PID of the last background command

    helm install rancher rancher-stable/rancher --namespace cattle-system -f values.yaml

    echo 'Wait 120 seconds...'
    sleep 120 & # Background sleep command
    display_spinner $! # Pass the PID of the last background command

    kubectl get pods -A
  else
    echo "Failed to install k3s. Exiting..."
  fi
}

main
