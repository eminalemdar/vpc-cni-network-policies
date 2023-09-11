#!/bin/bash
: '
The following script cleans up the resources created in
this repository gracefully.
'

declare AWS_REGION="eu-west-1"

cleanup(){

  echo "===================================================="
  echo "Creating required Environment Variables."
  echo "===================================================="

  declare ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')
  declare CLUSTER_NAME="eks-cluster-vpc-cni"
  declare OIDCURL=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -r 's/https:\/\///')

  echo "===================================================="
  echo "Deleting the OIDC Provider."
  echo "====================================================" 

  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDCURL}

  echo "===================================================="
  echo "Deleting the IAM Role."
  echo "===================================================="

  declare CNI_IAM_ROLE="vpc-cni"
  declare IAM_POLICY_NAME="AmazonEKS_CNI_Policy"
  declare IAM_POLICY_ARN="arn:aws:iam::aws:policy/${IAM_POLICY_NAME}"
  aws iam detach-role-policy --role-name ${CNI_IAM_ROLE} --policy-arn ${IAM_POLICY_ARN}
  aws iam delete-role --role-name ${CNI_IAM_ROLE}
  
  echo "===================================================="
  echo "Deleting the EKS Cluster."
  echo "====================================================" 

  terraform destroy --auto-approve
}

cleanup