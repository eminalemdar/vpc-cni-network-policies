#!/bin/bash
: '
The following script has two functions: 
Permissions function creates required IRSA config
and configures required IAM Permissions for the 
VPC CNI and connects those to the
service account.
CNI Config function updates the CNI Addon configuration
to enable Network Policy feature.
'

declare AWS_REGION="eu-west-1"
declare CLUSTER_NAME="eks-cluster-vpc-cni"

permissions(){
  # Configure Authentication for the Kubernetes Cluster
  aws eks --region $AWS_REGION update-kubeconfig --name $CLUSTER_NAME

  echo "===================================================="
  echo "Creating IRSA for EKS Cluster"
  echo "===================================================="

  ###########################################################
  # You can skip this step if you have already configured   #
  # IRSA for your Kubernetes Cluster.                       #
  ###########################################################
  
  eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve

  echo "===================================================="
  echo "Creating Required IAM Role and Policy"
  echo "===================================================="

  # Setting the required parameters for OIDC Provider.
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
  OIDC_PROVIDER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

  SYSTEM_NAMESPACE="kube-system"
  CNI_SERVICE_ACCOUNT="aws-node"

  # Creating IAM Trust Policy. 
  read -r -d '' TRUST_RELATIONSHIP <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SYSTEM_NAMESPACE}:${CNI_SERVICE_ACCOUNT}"
                }
            }
        }
    ]
  }
EOF
  echo "${TRUST_RELATIONSHIP}" > trust.json

  # Setting the required Environment Variables for IRSA (IAM Roles for Service Accounts).
  CNI_IAM_ROLE="vpc-cni"
  CNI_IAM_ROLE_DESCRIPTION='IRSA role for VPC CNI on EKS cluster'
  aws iam create-role --role-name "${CNI_IAM_ROLE}" --assume-role-policy-document file://trust.json --description "${CNI_IAM_ROLE_DESCRIPTION}"
  CNI_IAM_ROLE_ARN=$(aws iam get-role --role-name=${CNI_IAM_ROLE} --query Role.Arn --output text)

  # Attaching the EKS CNI policy to the IAM Role.
  IAM_POLICY_NAME="AmazonEKS_CNI_Policy"
  aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/${IAM_POLICY_NAME} --role-name ${CNI_IAM_ROLE}

  echo "===================================================="
  echo "Associating the Role with the Service Account"
  echo "===================================================="

  # Updating the Kubernetes Service Account with the new IAM Role
  declare IRSA_ROLE_ARN=eks.amazonaws.com/role-arn=${CNI_IAM_ROLE_ARN}
  kubectl annotate serviceaccount -n ${SYSTEM_NAMESPACE} ${CNI_SERVICE_ACCOUNT} ${IRSA_ROLE_ARN}

  echo "===================================================="
  echo "Re-deploying Amazon VPC CNI plugin for KubernetesPods"
  echo "===================================================="

  kubectl delete pods -n ${SYSTEM_NAMESPACE} -l k8s-app=${CNI_SERVICE_ACCOUNT}

}

cni_config(){
  echo "===================================================="
  echo "Updating CNI Configuration to enable Network Policies"
  echo "===================================================="

  ADDON_VERSION=$(aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name vpc-cni --region ${AWS_REGION} --query addon.addonVersion --output text)

  CNI_IAM_ROLE="vpc-cni"
  CNI_IAM_ROLE_ARN=$(aws iam get-role --role-name=${CNI_IAM_ROLE} --query Role.Arn --output text)
  aws eks update-addon --cluster-name ${CLUSTER_NAME} --addon-name vpc-cni --addon-version ${ADDON_VERSION} \
    --service-account-role-arn ${CNI_IAM_ROLE_ARN} \
    --resolve-conflicts PRESERVE --configuration-values '{"enableNetworkPolicy": "true"}'                   
}

permissions
cni_config