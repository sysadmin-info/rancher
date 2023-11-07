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

check_packages(){
  if [[ $(command -v git) ]]; then
    echo "git already installed"
  else
    sudo apt install git -y 
  fi

  if [[ $(command -v curl) ]]; then
    echo "curl already installed"
  else
    sudo apt install curl -y
  fi

  if [[ $(command -v iptables) ]]; then
    echo "iptables already installed"
  else
    sudo apt install iptables -y
    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  fi
}


install_k3s() {
  execute_command "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"v1.26.10+k3s1\" INSTALL_K3S_EXEC=\"--disable traefik\" K3S_KUBECONFIG_MODE=\"644\" sh -s -" || error_exit "Failed to install k3s"
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

install_rancher(){
  helm install rancher rancher-stable/rancher --namespace cattle-system -f values.yaml
}

generate_SAN_certs(){
  echo "************************ Root CA *************************************"
  cd /home/$USER
  echo "Step 1: Prepare Directories and Files for the CA"
  
  echo "a. Create directories to hold the CA's files and certificates."
  mkdir /home/$USER/ca /home/$USER/ca/intermediate
  
  echo "b. Create the database and serial files that the CA uses to track certificates."
  touch /home/$USER/ca/index.txt /home/$USER/ca/intermediate/index.txt
  echo 1000 > /home/$USER/ca/serial
  echo 1000 > /home/$USER/ca/intermediate/serial
  
  echo "**********************************************************************"
  echo "Step 2: Create the Root CA"
  
  echo "a. Generate the private key for the Root CA."
  openssl genrsa -aes256 -out /home/$USER/ca/root-ca.key 4096
  
  echo "b. Create the root certificate using the private key."
  echo "You’ll be prompted to enter details for the certificate."
  wget -O /home/$USER/ca/root-ca.cnf https://raw.githubusercontent.com/sysadmin-info/rancher/main/root-config.txt
  echo "CHANGE adrian to your user!!! in sed command"
  sed -i 's/$USER/adrian/g' /home/$USER/ca/root-ca.cnf
  openssl req -config /home/$USER/ca/root-ca.cnf -x509 -new -nodes -key /home/$USER/ca/root-ca.key -sha256 -days 3650 -out /home/$USER/ca/root-ca.crt -extensions v3_ca -config <(cat /home/$USER/ca/root-ca.cnf <(printf "\n[v3_ca]\nbasicConstraints = critical,CA:true\nkeyUsage = critical,keyCertSign,cRLSign"))
  chmod 444 /home/$USER/ca/root-ca.crt

  echo "**************************** Intermediate CA *********************************"
  echo "Step 3: Create the Intermediate CA"
  
  echo "a. Generate the private key for the Intermediate CA."
  openssl genrsa -aes256 -out /home/$USER/ca/intermediate/intermediate-ca.key 4096
  chmod 400 /home/$USER/ca/intermediate/intermediate-ca.key

  echo "b. Create a CSR for the Intermediate CA."
  echo "Fill in the details at the prompt."
  wget -O /home/$USER/ca/intermediate/intermediate-ca.cnf https://raw.githubusercontent.com/sysadmin-info/rancher/main/intermediate-config.txt
  echo "CHANGE adrian to your user!!! in sed command"
  sed -i 's/$USER/adrian/g' /home/$USER/ca/intermediate/intermediate-ca.cnf 
  openssl req -config /home/$USER/ca/intermediate/intermediate-ca.cnf -new -sha256 -key /home/$USER/ca/intermediate/intermediate-ca.key -out /home/$USER/ca/intermediate/intermediate-ca.csr
  cd /home/$USER/ca/intermediate
  cat > intermediate-ca.cnf <<EOF
[ v3_intermediate_ca ]
# Extensions for a typical intermediate CA
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
  
  cd /home/$USER

  echo "c. Sign the Intermediate CSR with the Root CA to create the Intermediate certificate."
  openssl x509 -req -in /home/$USER/ca/intermediate/intermediate-ca.csr -CA /home/$USER/ca/root-ca.crt -CAkey /home/$USER/ca/root-ca.key -CAcreateserial -out /home/$USER/ca/intermediate/intermediate-ca.crt -days 3650 -sha256 -extfile /home/$USER/ca/intermediate/intermediate-ca.cnf -extensions v3_intermediate_ca
  chmod 444 /home/$USER/ca/intermediate/intermediate-ca.crt

  echo "**************************** Rancher certificate *********************************"
  echo "Step 4: Create the Rancher Server Certificate"
  
  echo "a. Generate the private key for the server."
  openssl genrsa -aes256 -out /home/$USER/ca/intermediate/rancher-server.key 2048
  
  echo "b. Create a CSR for the Rancher Server."
  echo "Provide the details at the prompt, making sure the common name matches the domain name of the server."
  openssl req -new -sha256 -key /home/$USER/ca/intermediate/rancher-server.key -out /home/$USER/ca/intermediate/rancher-server.csr
  chmod 400 /home/$USER/ca/intermediate/rancher-server.key

  echo "c. Sign the CSR with the Intermediate CA to create the server certificate."
  echo "The v3.ext file should contain the necessary extensions for the web server certificate, like subjectAltName if needed."
  cd /home/adrian/ca/intermediate/
  cat > v3.ext <<EOF
[ v3_req ]
# Extensions to add to a certificate request
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = rancher.local
DNS.2 = www.rancher.local
IP.1 = 10.10.0.123
EOF
  openssl x509 -req -in /home/$USER/ca/intermediate/rancher-server.csr -CA /home/$USER/ca/intermediate/intermediate-ca.crt -CAkey /home/$USER/ca/intermediate/intermediate-ca.key -CAcreateserial -out /home/$USER/ca/intermediate/rancher-server.crt -days 365 -sha256 -extfile /home/$USER/ca/intermediate/v3.ext -extensions v3_req 
  
  echo "**************************** Certificate verification *********************************"
  echo "Step 5: Verify the Certificates"
  
  echo "a. After generating the certificates, verify them to make sure they form a valid chain."
  echo "If all goes well, this command should output web-server.crt: OK."
  openssl verify -CAfile /home/$USER/ca/root-ca.crt -untrusted /home/$USER/ca/intermediate/intermediate-ca.crt /home/$USER/ca/intermediate/rancher-server.crt

  echo "**********************************************************************"
  echo "Removing passphrase from Rancher certificate key"  
  cd /home/$USER
  openssl rsa -in /home/$USER/ca/intermediate/rancher-server.key -out /home/$USER/tls.key
  
  echo "**********************************************************************"
  echo "Make a chain in tls.crt"
  cat /home/$USER/ca/intermediate/rancher-server.crt /home/$USER/ca/intermediate/intermediate-ca.crt /home/$USER/ca/root-ca.crt > /home/$USER/tls.crt

  echo "**********************************************************************"
  echo "Copy Root CA to cacerts.pem"
  cp /home/$USER/ca/root-ca.crt /home/$USER/cacerts.pem
}

create_namespace(){
  kubectl create namespace cattle-system
}

# Place full chain cert into tls.crt file, private key to tls.key file
generate_secret_ingress(){
  kubectl -n cattle-system create secret tls tls-rancher-ingress --cert=tls.crt --key=tls.key
}

# put Root CA cert into cacerts.pem file according to 
# https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/add-tls-secrets#using-a-private-ca-signed-certificate
generate_secret_rancher_agent(){
  kubectl -n cattle-system create secret generic tls-ca --from-file=cacerts.pem=./cacerts.pem
}

generate_values(){
  cd /home/$USER/ 
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
privateCA: true

# http[s] proxy server passed into rancher server.
# proxy: http://example.local:1080

# comma separated list of domains or ip addresses that will not use the proxy
# noProxy: 127.0.0.0/8,10.42.0.0/16,10.43.0.0/16,10.10.0.0/24,rancher.local

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
  check_packages
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
    generate_SAN_certs
    generate_values
    create_namespace
    generate_secret_ingress
    generate_secret_rancher_agent

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo 'Wait 360 seconds for nginx ingress controller...'
    sleep 360 & # Background sleep command
    display_spinner $! # Pass the PID of the last background command
    install_rancher

    echo 'Wait 360 seconds for rancher pods ...'
    sleep 360 & # Background sleep command
    display_spinner $! # Pass the PID of the last background command

    kubectl get pods -A
  else
    echo "Failed to install k3s. Exiting..."
  fi
}

main
