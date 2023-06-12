#!/bin/bash
#its should be a template in future, we insert here pod network and other staff.
echo "Initializing K8S cluster.........."
echo "current pwd: $(pwd)" #current pwd: /
echo "whoami: $(whoami)" #whoami: root
echo "echo Home: $HOME" #Home: 
echo "Kubernetes version: ${kubernetes_version}"
echo "Pod network cidr: ${pod_network_cidr}"
echo "Service cidr: ${service_cidr}"
echo "Calico version: ${calico_version}"

AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
NAME_TAG=$(curl -s http://169.254.169.254/latest/meta-data/tags/instance/Name)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

#enable logs
sed -i -e "s/default-region/$AWS_REGION/g" -e "s/^region = [a-z0-9\-]*/region = eu-north-1/g" /etc/awslogs/awscli.conf
sed -i -e "s/REPLACE_LOG_GROUP_NAME/\${log_group_name}/g" -e "s/REPLACE_LOG_STREAM_SUFFIX/$NAME_TAG\/$INSTANCE_ID\/$INSTANCE_IP/g" /etc/awslogs/awslogs.conf
systemctl enable --now awslogsd.service
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "AWS logs agent has been enabled."

cat > /root/kubeadm-config.yaml <<EOF
#https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta3/
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: kubernetes
kubernetesVersion: ${kubernetes_version}
controlPlaneEndpoint: "${loadbalancer_dns_name}:6443"
networking:
  dnsDomain: cluster.local
  podSubnet: ${pod_network_cidr}
  serviceSubnet: ${service_cidr}
etcd:
  local:
    dataDir: /var/lib/etcd
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
dns: {}
apiServer:
  extraArgs:
    authorization-mode: Node,RBAC
  timeoutForControlPlane: 4m0s
controllerManager: {}
scheduler: {}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

sudo kubeadm init --config /root/kubeadm-config.yaml --upload-certs
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Cluster has been initialized."

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
#chown $(id -u):$(id -g) /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf
echo "Installing Calico..."
echo "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/tigera-operator.yaml"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/tigera-operator.yaml
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
sleep 10
echo "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/custom-resources.yaml"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/custom-resources.yaml
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Calico has been installed."

kubectl get nodes -o wide

SLAVE_JOIN_COMMAND=$(kubeadm token create --ttl=0 --print-join-command)
echo "Slave join command: $SLAVE_JOIN_COMMAND"
KUBEADM_CERTS_SECERT_PRIVATE_KEY=$(kubeadm init phase upload-certs --upload-certs --config /root/kubeadm-config.yaml | awk '/Using certificate key:/{getline; print}')
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Control plane certificates secret private key to download certs (the 'kubeadm-certs' will be deleted in 2h): $KUBEADM_CERTS_SECERT_PRIVATE_KEY"
MASTER_JOIN_COMMAND="$SLAVE_JOIN_COMMAND --control-plane --certificate-key $KUBEADM_CERTS_SECERT_PRIVATE_KEY"

#NEW_MASTER_JOIN_COMMAND=$(kubeadm token create --ttl=0 --print-join-command --certificate-key=$KUBEADM_CERTS_SECERT_PRIVATE_KEY)

aws --region=$AWS_REGION secretsmanager put-secret-value \
  --secret-id=${join_cluster_secret} \
  --secret-string="{\"${join_cluster_master_key}\":\"$MASTER_JOIN_COMMAND\",\"${join_cluster_slave_key}\":\"$SLAVE_JOIN_COMMAND\"}"
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
aws --region=$AWS_REGION secretsmanager put-secret-value \
  --secret-id=${cluster_config_secret} \
  --secret-string=file:///etc/kubernetes/admin.conf
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Secrets have been created. Creating a bomb that will terminate the bootstrapper when all master nodes join the cluster...."

cat > /root/bomb.sh <<EOF 
#!/bin/bash
if [[ ${k8s_master_asg_count} == 0 ]]; then
  echo "Looks like there is no K8S-Master ASG. Performing as a master node."
  exit 0
fi
echo "Waiting until ${k8s_master_asg_count} master nodes join the cluster and enter the ready state."
while [[ \$(kubectl get nodes | awk '\$2 == "Ready" && \$3 == "control-plane" {print \$2}' | wc -l) < \$((${k8s_master_asg_count}+1)) ]]
do
  kubectl get nodes -o wide
  sleep 10
done
echo "Cluster is ready! Updating the SSM parameter: ${ssm_parameter}."
aws --region=$AWS_REGION ssm put-parameter \\
  --name "${ssm_parameter}" \\
  --value "true" \\
  --overwrite
echo "Deregistering bootrapper node from the cluser"
kubeadm reset -f
kubectl drain --ignore-daemonsets $HOSTNAME
kubectl delete node $HOSTNAME

echo "Sleeping for 15 to send logs and perform shutdown."
sleep 15
echo "BYE"
shutdown -h now
EOF

nohup bash /root/bomb.sh &>> /var/log/cloud-init-output.log &
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "The bomb has been planted. User data has been executed."

# get node from etcd
# kubectl -n=kube-system exec etcd-ip-10-0-1-114.eu-north-1.compute.internal -- etcdctl --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/peer.crt --key /etc/kubernetes/pki/etcd/peer.key member list
# kubectl -n=kube-system exec etcd-ip-10-0-1-114.eu-north-1.compute.internal -- etcdctl --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/peer.crt --key /etc/kubernetes/pki/etcd/peer.key member remove 47d8ad052352c2ba
