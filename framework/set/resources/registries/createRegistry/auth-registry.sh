#!/usr/bin/bash

REGISTRY_USER=$1
REGISTRY_PASS=$2
REGISTRY_NAME=$3
HOST=$4
RANCHER_VERSION=$5
ASSET_DIR=$6
USER=$7
RANCHER_IMAGE=$8
RANCHER_AGENT_IMAGE=${9}

set -e

manageImages() {
    ACTION=$1
    mapfile -t IMAGES < /home/${USER}/rancher-images.txt
    PARALLEL_ACTIONS=10

    COUNTER=0
    for IMAGE in "${IMAGES[@]}"; do
        action "${ACTION}" "${IMAGE}"
        COUNTER=$((COUNTER+1))
        
        if (( $COUNTER % $PARALLEL_ACTIONS == 0 )); then
            wait
        fi
    done

    wait
}

action() {
    ACTION=$1
    IMAGE=$2
    
    if [ "$ACTION" == "pull" ]; then
        sudo docker pull ${IMAGE} && sudo docker tag ${IMAGE} ${HOST}/${IMAGE} &
    elif [ "$ACTION" == "push" ]; then
        sudo docker push ${HOST}/${IMAGE} &
    fi
}

echo "Setting up htpasswd..."
. /etc/os-release

[[ "${ID}" == "ubuntu" || "${ID}" == "debian" ]] && sudo apt update && sudo apt install -y apache2-utils wget
[[ "${ID}" == "rhel" || "${ID}" == "fedora" ]] && sudo yum install -y httpd-tools wget
[[ "${ID}" == "opensuse-leap" || "${ID}" == "sles" ]] && sudo zypper install -y apache2-utils wget

if [ "$(sudo docker ps -q -f name=${REGISTRY_NAME})" ]; then
    echo "Private registry ${REGISTRY_NAME} already exists. Skipping..."
else
    sudo mkdir -p /home/${USER}/auth
    sudo htpasswd -Bbn ${REGISTRY_USER} ${REGISTRY_PASS} | sudo tee /home/${USER}/auth/htpasswd

    echo "Creating a self-signed certificate..."
    sudo mkdir -p /home/${USER}/certs
    sudo openssl req -newkey rsa:4096 -nodes -sha256 -keyout /home/${USER}/certs/domain.key -addext "subjectAltName = DNS:${HOST}" -x509 -days 365 -out /home/${USER}/certs/domain.crt -subj "/C=US/ST=CA/L=SUSE/O=Dis/CN=${HOST}"

    echo "Copying the certificate to the /etc/docker/certs.d/${HOST} directory..."
    sudo mkdir -p /etc/docker/certs.d/${HOST}
    sudo cp /home/${USER}/certs/domain.crt /etc/docker/certs.d/${HOST}/ca.crt

    echo "Creating a private registry..."
    sudo docker run -d --restart=always --name "${REGISTRY_NAME}" -v /home/${USER}/auth:/auth -v /home/${USER}/certs:/certs \
                                                                                                    -e REGISTRY_AUTH=htpasswd \
                                                                                                    -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
                                                                                                    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
                                                                                                    -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
                                                                                                    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
                                                                                                    -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
                                                                                                    -p 443:443 \
                                                                                                    registry:2


    echo "Logging into the private registry..."
    sudo docker login https://${HOST} -u ${REGISTRY_USER} -p ${REGISTRY_PASS}
fi

sudo wget ${ASSET_DIR}${RANCHER_VERSION}/rancher-images.txt -O /home/${USER}/rancher-images.txt
sudo wget ${ASSET_DIR}${RANCHER_VERSION}/rancher-windows-images.txt -O /home/${USER}/rancher-windows-images.txt
sudo wget ${ASSET_DIR}${RANCHER_VERSION}/rancher-save-images.sh -O /home/${USER}/rancher-save-images.sh
sudo wget ${ASSET_DIR}${RANCHER_VERSION}/rancher-load-images.sh -O /home/${USER}/rancher-load-images.sh
    
sudo chmod +x /home/${USER}/rancher-save-images.sh && sudo chmod +x /home/${USER}/rancher-load-images.sh
sudo sed -i "s/docker save/# docker save /g" /home/${USER}/rancher-save-images.sh
sudo sed -i "s/docker load/# docker load /g" /home/${USER}/rancher-load-images.sh
sudo sed -i '/mirrored-prometheus-windows-exporter/d' /home/${USER}/rancher-images.txt

if [ ! -z "${RANCHER_AGENT_IMAGE}" ]; then
    sudo sed -i "s|rancher/rancher:|${RANCHER_IMAGE}:|g" /home/${USER}/rancher-images.txt
    sudo sed -i "s|rancher/rancher-agent:|${RANCHER_AGENT_IMAGE}:|g" /home/${USER}/rancher-images.txt
fi

echo "Pulling the images..."
manageImages "pull"

echo "Pushing the newly tagged images..."
manageImages "push"