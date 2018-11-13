#!/bin/bash -ex
## Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
## SPDX-License-Identifier: MIT-0
IFS=" "
/opt/halyard/bin/halyard > /dev/null 2>&1 &

usage() {
cat """
Usage: $0
    -S      SSM Secrets, the script will attempt to pull secrets from SSM to fill in authentication and other settings from SSM
    -g      Github Organization, if set and other AUTHN and AUTHZ secrets set this is the org to be used for AUTHN and AUTHZ in Spinnaker
    -r      AWS Region, where the S3 bucket for Spinnaker is located
    -f      Load balancer security group, places the security group provided on the AWS load balancers to lock them down.
    -s      Spinnaker Version number
    -h      Help, print this help message
""" 1>&2; exit 1;
}

while getopts "S:g:r:f:s:" o; do
    case "${o}" in
        S)
            USE_SSM_FOR_SECRETS=${OPTARG}
            ;;
        g)
            GITHUB_ORG=${OPTARG}
            ;;
        r)
            REGION=${OPTARG}
            ;;
        f)
            LB_SG=${OPTARG}
            ;;
        s)
            SPINNAKER_VERSION=${OPTARG}
            ;;
        h)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

EKS_EC2_VPC_STACK_NAME="spin-eks-ec2-vpc"

if [ -z "${REGION}" ]; then
    REGION="us-west-2"
fi

if [ "${USE_SSM_FOR_SECRETS}" == true ]; then
    LB_SG=""
    AUTHN_CLIENT_ID=$(aws ssm get-parameters --names github-authn-client-id --with-decryption --query Parameters[0].Value --output text)
    AUTHN_CLIENT_SECRET=$(aws ssm get-parameters --names github-authn-client-secret --with-decryption --query Parameters[0].Value --output text)
    AUTHZ_ACCESS_TOKEN=$(aws ssm get-parameters --names github-authz-token --with-decryption --query Parameters[0].Value --output text)
    GITHUB_ORG=$(aws ssm get-parameters --names github-org --with-decryption --query Parameters[0].Value --output text)
    PREFIX_LIST=$(aws ssm get-parameters --names sg-prefix-list --with-decryption --query Parameters[0].Value --output text)
    if [ "${AUTHN_CLIENT_ID}" = "None" ] || [ "${AUTHN_CLIENT_SECRET}" = "None" ] || [ "${AUTHZ_ACCESS_TOKEN}" = "None" ] || [ "${PREFIX_LIST}" = "None" ]; then
        echo "One of github-authn-client-id, github-authn-client-secret, github-authz-token, or sg-prefix-list is not in SSM"
        exit 1
    fi
fi

BAKING_VPC=$(aws ec2 describe-vpcs --filters Name=cidr,Values=172.31.0.0/16 --query Vpcs[0].VpcId --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SPINNAKER_BUCKET=$(aws cloudformation describe-stacks --stack-name ${EKS_EC2_VPC_STACK_NAME} --query 'Stacks[0].Outputs[?OutputKey==`SpinnakerDataBucket`].OutputValue' --output text | cut -d ":" -f6)
SPINNAKER_MANAGED_ROLE="role/SpinnakerManaged"

echo "Creating some kubernetes resources before running halyard"
kubectl apply -f resources/kubernetes/lb-services.yaml -n spinnaker
kubectl apply -f resources/kubernetes/spinnaker-k8s-role.yaml

GATE_ADDRESS=$(kubectl describe svc gate-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
DECK_ADDRESS=$(kubectl describe svc deck-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
until [ "${GATE_ADDRESS}" != "" ]; do
    GATE_ADDRESS=$(kubectl describe svc gate-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
    sleep 30
done
until [ "${DECK_ADDRESS}" != "" ]; do
    DECK_ADDRESS=$(kubectl describe svc deck-lb -n spinnaker | grep LoadBalancer\ Ingress | awk '{print $3}')
done


GATE_LB=$(echo ${GATE_ADDRESS} | cut -d "-" -f1)
DECK_LB=$(echo ${DECK_ADDRESS} | cut -d "-" -f1)
GATE_SG=$(aws elb describe-load-balancers --load-balancer-names ${GATE_LB} --query LoadBalancerDescriptions[0].SecurityGroups[0] --output text)
DECK_SG=$(aws elb describe-load-balancers --load-balancer-names ${DECK_LB} --query LoadBalancerDescriptions[0].SecurityGroups[0] --output text)

if [ ! -z "${PREFIX_LIST}" ]; then
    for SG in "${GATE_SG}" "${DECK_SG}"; do
        aws ec2 revoke-security-group-ingress --group-id ${SG} --protocol tcp --port 80 --cidr 0.0.0.0/0 || true
        aws ec2 describe-security-groups --group-ids ${SG} | grep ${PREFIX_LIST} && echo "Found prefix list, skipping adding exception" || \
        aws ec2 authorize-security-group-ingress --group-id ${SG} --ip-permissions '[{"FromPort":80,"IpProtocol":"tcp","PrefixListIds":[{"Description":"prefix-list-restriction","PrefixListId":"pl-f8a64391"}],"ToPort":80}]'
    done
elif [ ! -z "${LB_SG}" ]; then
    for LB in "${GATE_LB}" "${DECK_LB}"; do
        PREV_GROUPS=$(aws elb describe-load-balancers --load-balancer-names ${LB} --query LoadBalancerDescriptions[0].SecurityGroups[*] --output text | tr "\t" " ")
        NEW_GROUPS=""
        for GRP in ${PREV_GROUPS}; do
            if [ "${GRP}" = "${LB_SG}" ]; then
                echo "Do nothing"
            else
                NEW_GROUPS="${NEW_GROUPS} ${GRP}"
            fi
        done
        NEW_GROUPS=$(echo ${NEW_GROUPS} | sed -e 's/^[ \t]*//')
        NEW_GROUPS="${NEW_GROUPS} ${LB_SG}"
        aws elb apply-security-groups-to-load-balancer --load-balancer-name ${LB} --security-groups ${NEW_GROUPS}
        for PREV_GROUP in ${PREV_GROUPS}; do
            if [ "${PREV_GROUP}" != "${LB_SG}" ]; then
                aws ec2 revoke-security-group-ingress --group-id ${PREV_GROUP} --protocol tcp --port 80 --cidr 0.0.0.0/0 || true
            fi
        done
    done
fi

sleep 30

echo "Executing Halyard commands to create a Halyard configuration file"
hal --color false config provider aws account add my-aws-account \
    --account-id ${ACCOUNT_ID} \
    --assume-role ${SPINNAKER_MANAGED_ROLE} \
    --regions us-west-2

hal --color false config provider aws bakery edit --aws-vpc-id ${BAKING_VPC}
hal --color false config provider aws enable

hal --color false config provider kubernetes account add my-k8s-account --provider-version v2 --context spinnaker-context --namespaces default,spinnaker
hal --color false config features edit --artifacts true
hal --color false config provider kubernetes enable

hal --color false config provider ecs account add my-ecs-account --aws-account my-aws-account
hal --color false config provider ecs enable

hal --color false config storage s3 edit \
    --bucket ${SPINNAKER_BUCKET} \
    --region ${REGION}

hal --color false config storage edit --type s3

hal --color false config security ui edit --override-base-url http://${DECK_ADDRESS}
hal --color false config security api edit --override-base-url http://${GATE_ADDRESS}

if [ ! -z "${AUTHN_CLIENT_ID}" ] && [ ! -z "${AUTHN_CLIENT_SECRET}" ] && [ ! -z "${AUTHZ_ACCESS_TOKEN}" ] && [ ! -z "${GITHUB_ORG}" ]; then
    hal --color false config security authn oauth2 edit \
      --client-id ${AUTHN_CLIENT_ID} \
      --client-secret ${AUTHN_CLIENT_SECRET} \
      --provider github
    hal --color false config security authn oauth2 enable
    ## Once this https://github.com/spinnaker/spinnaker/issues/3154 is fixed we can use just run the commands
#    sed -ie "s|roleProviderType:\ GITHUB|roleProviderType:\ GITHUB\n          baseUrl: https://api.github.com\n          accessToken: ${AUTHZ_ACCESS_TOKEN}\n          organization: ${GITHUB_ORG}|g" /home/spinnaker/.hal/config
#    hal --color false config security authz enable
fi

hal --color false config deploy edit --type distributed --account-name my-k8s-account

hal --color false config version edit --version ${SPINNAKER_VERSION}

#mkdir -p /home/spinnaker/.hal/default/service-settings
#cp resources/halyard/deck.yml /home/spinnaker/.hal/default/service-settings/deck.yml

hal --color false deploy apply

set +x
echo "The Spinnaker UI (deck) should be accessible at the following address: ${DECK_ADDRESS}"
echo "The Spinnaker API server (gate) should be at the following address: ${GATE_ADDRESS}"
