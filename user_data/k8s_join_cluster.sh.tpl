#!/bin/bash
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

echo "Disabling source/destination check"
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --source-dest-check "{\"Value\": false}" --region $AWS_REGION
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Source/destination check have been disabled"

echo "Getting cluster config from ${cluster_config_secret}"
mkdir -p /root/.kube
K8S_CLUSTER_CONFIG_SECRET=$(aws --region=$AWS_REGION secretsmanager get-secret-value --secret-id=${cluster_config_secret} --query "SecretString")
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo -e "$(echo "$K8S_CLUSTER_CONFIG_SECRET" | sed -e 's/^"//' -e 's/"$//')" > /root/.kube/config
#chown $(id -u):$(id -g) /root/.kube/config
chmod 600 /root/.kube/config

echo "Getting join command from ${join_cluster_secret} , key: ${join_cluster_secret_key}"
K8S_JOIN_COMMAND_SECRET=$(aws --region=$AWS_REGION secretsmanager get-secret-value --secret-id=${join_cluster_secret})
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
K8S_JOIN_COMMAND=$(echo $K8S_JOIN_COMMAND_SECRET | jq -r .SecretString | jq -r ."${join_cluster_secret_key}")
echo $K8S_JOIN_COMMAND
n=0
while [[ $n < 5 ]]
do
  n=$((n+1))
  sleep 10
  $K8S_JOIN_COMMAND && break
done
EXIT_CODE=$?
if [[ $EXIT_CODE != 0 ]]; then
  echo "Failure: $EXIT_CODE" && exit $EXIT_CODE
fi
echo "Joined to the cluster!"
