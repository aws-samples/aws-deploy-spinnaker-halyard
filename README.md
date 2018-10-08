# Halyard deploy

This repo is intended to:

1. Create an EKS cluster for Spinnaker to be deployed to
1. Deploy Spinnaker using halyard

This is mostly for demo environment purposes, and there are some overly permissive IAM roles in places. If you wish to run this in production, you should modify the permissive roles to be more restrictive. This is intended to run as-is in a brand new AWS account.

# Pre-requisites 

This repository assumes you have a new AWS account and wish to test Spinnaker out, you will need:

1. AWS CLI credentials setup for a user with at least Administrator access to create resources
1. Access to create EC2 security groups
 
# Quick Start

1. Fork this repository on GitHub (or CodeCommit)
2. Run the following from a terminal with aws cli access to your account (change GITHUB to CODECOMMIT if code is uploaded there)

    ```
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    aws cloudformation create-stack --stack-name codebuild-projects \
        --template-body "$(cat resources/cloudformation/codebuild-projects.yaml)" \
        --parameters ParameterKey=CodeBuildArtifactsBucketName,ParameterValue=codebuild-artifacts-${ACCOUNT_ID} \
                     ParameterKey=SourceLocation,ParameterValue=https://github.com/aws-samples/aws-deploy-spinnaker-halyard \
                     ParameterKey=SourceType,ParameterValue=GITHUB \
        --capabilities CAPABILITY_NAMED_IAM
    aws ec2 create-key-pair --key-name spinnaker-eks-keypair
    ```
3. Navigate to CodeBuild
4. Start the create-eks CodeBuild project
5. Create a security group in the EKS-VPC to lock-down the Spinnaker load balancers take note of the security group id.
6. Start the deploy-spinnaker CodeBuild project, fill in the environment variable "SECURITY_GROUP_ID" with the security group id from the previous step 

Spinnaker will be available at the UI/Deck address emitted at the end of the deploy-spinnaker CodeBuild job.

# Cleaning up

The CodeBuild project "cleanup-infrastructure" will delete all objects associated with all the cloudformation stacks in this project except the CodeBuild projects stack. For the stack to delete *everything* you must specify the FORCE_DELETE parameter to true, this will empty the Spinnaker infra bucket of data before deleting the CloudFormation stack that defines the Spinnaker data bucket. This at the moment is a best effort there might be resources created by Spinnaker or other processes that will need to be manually deleted before the Spinnaker CloudFormation can be deleted.

# Accessing EKS

You will need to add your user ARN to the EKS-Admin role, once this done you can download the EKS kubeconfig with the following command

```$bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp s3://codebuild-artifacts-${ACCOUNT_ID}/create-eks/files/resources/kubernetes/kubeconfig.yaml /tmp/kube/config
export KUBECONFIG=/tmp/kube/config
kubectl get pods -n spinnaker
``` 

Once it is downloaded you can run kubectl commands as normal to read and output logs and see pod status.

# Exposing Services

See the [buildspec section](#modifying-buildspec-for-authentication-and-security-groups) for some supplemental information.

The code in this repository will create two load balancers using the EKS and EC2 integrations, these services are created in the deploy_spinnaker.sh. When created these load balancers are open to the world, so there are few flags in the deploy_spinnaker.sh to give you options on locking down the security groups, the flags in this example will apply the security group specified in the deploy_spinnaker.sh script to the load balancers to lock down load balancers.

# Modifying the Spinnaker installation

If you need to tweak the halyard settings that are applied to the Spinnaker installation this can be accomplished by modifying the `deploy_spinnaker.sh` script. Once modified you can upload your changes to the source control, and then rerun the deploy-spinnaker CodeBuild job to apply the changes.

# Feedback

This repository is meant to be an easy method of deploying Spinnaker to a brand new AWS account for demo purposes. Not all use cases are meant to be covered, but if new use cases can be added without making the repository difficult to use, then they are more than welcome. You can submit changes or fixes to this repository by submitting a pull request on this repository. We will review and provide feedback, we might need further follow up from pull request authors to make changes.





 
