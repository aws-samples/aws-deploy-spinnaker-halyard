#!/bin/bash -ex
## Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
## SPDX-License-Identifier: MIT-0

usage() {
cat """
Usage: $0
	-m      Managing profile, the AWS cli profile where the EKS cluster will be deployed
	-k      (Required) Kubernetes cluster name, the name of the Kubernetes cluster to be created
	-s      (Required) Kubernetes worker keypair, the keypair for the EC2 worker nodes
	-b      (Required) Spinnaker bucket name, this must be globally unique
	-h      Help, print this help message
""" 1>&2; exit 1;
}

while getopts ":m:k:s:hb:" o; do
    case "${o}" in
        m)
            export AWS_PROFILE=${OPTARG}
            ;;
        k)
            K8S_NAME=${OPTARG}
            ;;
        s)
            K8S_KEYPAIR=${OPTARG}
            ;;
        b)
            SPINNAKER_BUCKET=${OPTARG}
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "${MANAGING_PROFILE}" ]; then
    echo "Missing managing profile: -m, assuming none"
    unset AWS_PROFILE
fi

if [ -z "${K8S_NAME}" ]; then
    echo "Missing Kubernetes cluster name: -k"
    usage
    exit 1
fi

if [ -z "${K8S_KEYPAIR}" ]; then
    echo "Missing Kubernetes worker keypair: -s"
    usage
    exit 1
fi

if [ -z "${SPINNAKER_BUCKET}" ]; then
    echo "Missing Spinnaker bucket name: -b"
    usage
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
WORKER_AMI="ami-0a54c984b9f908c81"
WORKER_TYPE="t2.large"
EKS_EC2_VPC_STACK_NAME="spin-eks-ec2-vpc"
EKS_WORKER_STACK_NAME="spinnaker-infra-eks-nodes"
CODEBUILD_STACK_NAME="codebuild-projects"

function createEKS {
    STACK_NAME=${1}
    SPINNAKER_BUCKET=${2}
    ACCOUNT_ID=${3}
    echo "Checking for and creating ${STACK_NAME}"
    aws cloudformation describe-stacks --stack-name ${STACK_NAME} && echo "${STACK_NAME} already exists" || \
        aws cloudformation create-stack \
            --stack-name ${STACK_NAME} \
            --template-body "$(cat resources/cloudformation/spinnaker-eks-ec2.yaml)" \
            --parameters "ParameterKey=SpinnakerBucketName,ParameterValue=${SPINNAKER_BUCKET}-${ACCOUNT_ID}" \
            --capabilities CAPABILITY_NAMED_IAM
    echo "Waiting for stack creation complete"
    aws cloudformation wait stack-create-complete --stack-name ${STACK_NAME}
    echo "Stack creation is now complete"
    unset STACK_NAME
}

function createEKSWorkers {
    EKS_WORKER_STACK_NAME=${1}
    K8S_NAME=${2}
    K8S_KEYPAIR=${3}
    WORKER_AMI=${4}
    WORKER_TYPE=${5}
    ACCOUNT_ID=${6}
    NETWORK_STACK_NAME=${7}
    echo "Creating EKS worker nodes"
    aws cloudformation describe-stacks --stack-name ${EKS_WORKER_STACK_NAME} && echo "stack ${EKS_WORKER_STACK_NAME} already exists" || \
        aws cloudformation deploy --stack-name ${EKS_WORKER_STACK_NAME} \
            --template-file resources/cloudformation/spinnaker-eks-nodegroup.yaml \
            --parameter-overrides ClusterName=${K8S_NAME} KeyName=${K8S_KEYPAIR} SpinnakerBucketName=${SPINNAKER_BUCKET}-${ACCOUNT_ID} \
                NodeGroupName=spinnaker-eks NodeImageId=${WORKER_AMI} NodeInstanceType=${WORKER_TYPE} NetworkStackName=${NETWORK_STACK_NAME} \
            --capabilities CAPABILITY_NAMED_IAM
    aws cloudformation wait stack-create-complete --stack-name ${EKS_WORKER_STACK_NAME}
}

function renderKubeConfig {
    K8S_ENDPOINT=${1}
    CA_DATA=${2}
    K8S_NAME=${3}
    EKS_ADMIN_ARN=${4}
    mkdir -p resources/kubernetes/
    if [ -z "${EKS_ADMIN_ARN}" ]; then
        echo "Rendering without role iam access"
        sed -e "s|%%K8S_ENDPOINT%%|${K8S_ENDPOINT}|g;s|%%CA_DATA%%|${CA_DATA}|g;s|%%K8S_NAME%%|${K8S_NAME}|g" < templates/kubeconfig.tmpl.yaml > resources/kubernetes/kubeconfig.yaml
    else
        echo "Rendering with role iam access"
        mv resources/kubernetes/kubeconfig.yaml resources/kubernetes/kubeconfig-no-role.yaml
        sed -e "s|%%K8S_ENDPOINT%%|${K8S_ENDPOINT}|g;s|%%CA_DATA%%|${CA_DATA}|g;s|%%K8S_NAME%%|${K8S_NAME}|g;s|%%EKS_ADMIN_ARN%%|${EKS_ADMIN_ARN}|g" < templates/kubeconfig-with-role.tmpl.yaml > resources/kubernetes/kubeconfig.yaml
    fi
}

function updateKubeRoles {
    export KUBECONFIG=${1}
    EKS_ADMIN_ARN=${2}
    EKS_NODE_INSTANCE_ROLE_ARN=${3}
    CODEBUILD_ROLE_ARN=${4}
    if kubectl get svc; then
        echo "Have connectivity to kubernetes, updating with EKS admins role access and worker nodes"
        sed -e "s|%%EKS_ADMIN_ARN%%|${EKS_ADMIN_ARN}|g;s|%%CODEBUILD_ROLE_ARN%%|${CODEBUILD_ROLE_ARN}|g;s|%%EKS_NODE_INSTANCE_ROLE_ARN%%|${EKS_NODE_INSTANCE_ROLE_ARN}|g" < templates/aws-auth-cm.tmpl.yaml > resources/kubernetes/aws-auth-cm.yaml
        kubectl apply -f resources/kubernetes/aws-auth-cm.yaml
    fi
}

function main {
    createEKS ${EKS_EC2_VPC_STACK_NAME} ${SPINNAKER_BUCKET} ${ACCOUNT_ID}
    createEKSWorkers ${EKS_WORKER_STACK_NAME} ${K8S_NAME} ${K8S_KEYPAIR} ${WORKER_AMI} ${WORKER_TYPE} ${ACCOUNT_ID} ${EKS_EC2_VPC_STACK_NAME}
    EKS_NODE_INSTANCE_ROLE_ARN=$(aws cloudformation describe-stacks --stack-name ${EKS_WORKER_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`NodeInstanceRole`].OutputValue' --output text)
    K8S_ENDPOINT=$(aws eks describe-cluster --name ${K8S_NAME} --query 'cluster.endpoint' --output text)
    CA_DATA=$(aws eks describe-cluster --name ${K8S_NAME} --query 'cluster.certificateAuthority.data' --output text)
    renderKubeConfig ${K8S_ENDPOINT} ${CA_DATA} ${K8S_NAME}
    EKS_ADMIN_ROLE=$(aws cloudformation describe-stacks --stack-name ${EKS_EC2_VPC_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`EKSAdminRole`].OutputValue' --output text)
    EKS_ADMIN_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EKS_ADMIN_ROLE}"
    CODEBUILD_PROJECT_ROLE=$(aws cloudformation describe-stacks --stack-name ${CODEBUILD_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`CreateEKSSpinnakerRole`].OutputValue' --output text)
    CODEBUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_PROJECT_ROLE}"
    updateKubeRoles resources/kubernetes/kubeconfig.yaml ${EKS_ADMIN_ARN} ${EKS_NODE_INSTANCE_ROLE_ARN} ${CODEBUILD_ROLE_ARN}
    renderKubeConfig ${K8S_ENDPOINT} ${CA_DATA} ${K8S_NAME} ${EKS_ADMIN_ARN}
    if [ -f /sys/hypervisor/uuid ] && [ `head -c 3 /sys/hypervisor/uuid` == ec2 ]; then
        if KUBECONFIG=resources/kubernetes/kubeconfig-no-role.yaml kubectl get nodes; then
            echo "If you see nodes here, congrats"
        else
            echo "Something went horribly wrong"
        fi
        CONTEXT="spinnaker"
        export KUBECONFIG=resources/kubernetes/kubeconfig-no-role.yaml
        kubectl describe namespace spinnaker && echo "Namespace already exists" || kubectl create namespace spinnaker
        kubectl apply -f resources/kubernetes/spinnaker-k8s-role.yaml
        TOKEN=$(kubectl get secret \
            $(kubectl get serviceaccount spinnaker-service-account \
               -n spinnaker \
               -o jsonpath='{.secrets[0].name}') \
           -n spinnaker \
           -o jsonpath='{.data.token}' | base64 -d)
        kubectl config set-credentials ${CONTEXT}-token-user --token ${TOKEN}
        kubectl config set-credentials ${CONTEXT}-token-user --token ${TOKEN}
        kubectl config set-context spinnaker-context --cluster=kubernetes --user=spinnaker-token-user
    else
        if KUBECONFIG=resources/kubernetes/kubeconfig.yaml kubectl get nodes; then
            echo "Running with role, if you see nodes here, congrats"
        else
            echo "Something went horrible wrong with a role"
        fi
    fi
    ./scripts/create_spinnaker_managed.sh -a ${EKS_NODE_INSTANCE_ROLE_ARN}
    # We need to create a load balancer and delete it so we can make EKS lbs
    SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name ${EKS_EC2_VPC_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`EKSSubnetIds`].OutputValue' --output text)
    SUBNET_ID=$(echo "${SUBNET_IDS}" | cut -d "," -f 1)
    aws elb create-load-balancer --load-balancer-name temp-lb-${ACCOUNT_ID} --listeners "Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80" --subnets "${SUBNET_ID}"
    aws elb delete-load-balancer --load-balancer-name temp-lb-${ACCOUNT_ID}
}

main