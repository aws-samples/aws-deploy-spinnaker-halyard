#!/bin/bash -ex
## Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
## SPDX-License-Identifier: MIT-0

usage() {
cat """
Usage: $0
	-k      (Required) Kubernetes cluster name, the name of the Kubernetes cluster to be created
	-f      (Required) Security group ID to be cleaned up, this is the one you made manually
	-d      (Boolean) Set to true to delete the spinnaker data bucket contents
	-h      Help, print this help message
""" 1>&2; exit 1;
}

while getopts "k:f:d:" o; do
    case "${o}" in
        k)
            K8S_NAME=${OPTARG}
            ;;
        f)
            SG_ID=${OPTARG}
            ;;
        d)
            FORCE_DELETE=${OPTARG}
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;

    esac
done

if [ -z "${K8S_NAME}" ]; then
    K8S_NAME=spinnaker-infra
fi

GATE_ADDRESS=$(kubectl describe svc gate-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
DECK_ADDRESS=$(kubectl describe svc deck-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
GATE_LB=$(echo ${GATE_ADDRESS} | cut -d "-" -f1)
DECK_LB=$(echo ${DECK_ADDRESS} | cut -d "-" -f1)
if [ ! -z "${GATE_LB}" ] && [ ! -z "${DECK_LB}" ]; then
    for LB in "${GATE_LB}" "${DECK_LB}"; do
        aws elb apply-security-groups-to-load-balancer --load-balancer-name ${LB} --security-groups ""
    done
fi
VPC_ID=$(aws cloudformation describe-stacks --stack-name spin-eks-ec2-vpc --query 'Stacks[0].Outputs[?OutputKey==`EKSVpcId`].OutputValue' --output text)

kubectl delete svc gate-lb -n spinnaker || echo "gate-lb already gone"
kubectl delete svc deck-lb -n spinnaker || echo "deck-lb already gone"

sleep 30

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws cloudformation delete-stack --stack-name spinnaker-managed-${ACCOUNT_ID}
aws cloudformation wait stack-delete-complete --stack-name spinnaker-managed-${ACCOUNT_ID}
aws cloudformation delete-stack --stack-name spinnaker-infra-eks-nodes
aws cloudformation wait stack-delete-complete --stack-name spinnaker-infra-eks-nodes
aws ec2 delete-security-group --group-id ${SG_ID} || echo "security group already gone"
sleep 5
DEFAULT=$(aws ec2 describe-security-groups --filter Name="vpc-id",Values="${VPC_ID}" --query "SecurityGroups[?GroupName=='default']|[].GroupId" --output text)
EKS_SG=$(aws cloudformation describe-stacks --stack-name spin-eks-ec2-vpc --query 'Stacks[0].Outputs[?OutputKey==`EKSSecurityGroups`].OutputValue' --output text)
if [ "$(uname)" = "Darwin" ]; then
    aws ec2 describe-security-groups --filters Name="vpc-id",Values="${VPC_ID}" --query SecurityGroups[].GroupId --output text | \
        tr "\t" "\n" | grep -v ${DEFAULT} | grep -v ${EKS_SG} | xargs -I {} sh -c "aws ec2 delete-security-group --group-id {} && sleep 5"
else
  aws ec2 describe-security-groups --filters Name="vpc-id",Values="${VPC_ID}" --query SecurityGroups[].GroupId --output text | \
        tr "\t" "\n" | grep -v ${DEFAULT} | grep -v ${EKS_SG} | xargs -I {} sh -c "aws ec2 delete-security-group --group-id {} && sleep 5"
fi

if [ "${FORCE_DELETE}" = "true" ]; then
    echo "Deleting contents of spinnaker data bucket"
    BUCKET=$(aws cloudformation describe-stacks --stack-name spin-eks-ec2-vpc --query 'Stacks[0].Outputs[?OutputKey==`SpinnakerDataBucket`].OutputValue' --output text)
    aws s3 rm s3://${BUCKET} --recursive
    aws cloudformation delete-stack --stack-name spin-eks-ec2-vpc
    aws cloudformation wait stack-delete-complete --stack-name spin-eks-ec2-vpc
    exit 0
else
    echo "You did not specify force deleting the s3 bucket, exiting"
    exit 0
fi

