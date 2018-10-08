## Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
## SPDX-License-Identifier: MIT-0
#!/bin/bash -e

usage() {
cat """
Usage: $0
	-p      Managed profile, profile that will be managed by Spinnaker
	-m      Managing profile, the profile that has Spinnaker residing in it and that will manage other accounts
	-a      Authentication ARN, this the ARN that will assume the spinnakerManaged role in the managed accounts
	-h      Help, print this help message
""" 1>&2; exit 1;
}

while getopts ":p:m:a:" o; do
    case "${o}" in
        p)
            MANAGED_PROFILE=${OPTARG}
            ;;
        m)
            MANAGING_PROFILE=${OPTARG}
            ;;
        a)
            AUTH_ARN=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${AUTH_ARN}" ]; then
    usage
    exit 1
fi

mkdir -p resources
if [ -z "${MANAGING_PROFILE}" ]; then
    MANAGING_ID=$(aws sts get-caller-identity --query Account --output text)
else
    MANAGING_ID=$(aws --profile ${MANAGING_PROFILE} sts get-caller-identity --query Account --output text)
fi

PARAM_STRING="ParameterKey=AuthArn,ParameterValue=${AUTH_ARN} ParameterKey=ManagingAccountId,ParameterValue=${MANAGING_ID}"


if [ -z "${MANAGED_PROFILE}" ]; then
    if aws cloudformation describe-stacks --stack-name spinnaker-managed-${MANAGING_ID}; then
        echo "Managed role already created"
    else
        aws cloudformation create-stack --stack-name spinnaker-managed-${MANAGING_ID} --template-body "$(cat resources/cloudformation/spinnaker-managed.yaml)" \
            --parameters ${PARAM_STRING} \
            --capabilities CAPABILITY_NAMED_IAM
    fi
else
    if aws --profile ${MANAGED_PROFILE} cloudformation describe-stacks --stack-name spinnaker-managed-${MANAGING_ID}; then
        echo "Managed role already created"
    else
        aws --profile ${MANAGED_PROFILE} cloudformation create-stack --stack-name spinnaker-managed-${MANAGING_ID} --template-body "$(cat resources/cloudformation/spinnaker-managed.yaml)" \
            --parameters ${PARAM_STRING} \
            --capabilities CAPABILITY_NAMED_IAM
    fi
fi