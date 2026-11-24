set -u
export PATH=/opt/homebrew/bin:$PATH AWS_REGION=us-west-2 AWS_PAGER=""
ACCT=096391855278; KEY=arn:aws:kms:us-west-2:$ACCT:key/be355c93-86d8-42d3-8a5c-93cfc8d5448b
cd /tmp
cat > trust.json <<J
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
J
cat > policy.json <<J
{"Version":"2012-10-17","Statement":[
 {"Sid":"SignWithIssuingKeyOnly","Effect":"Allow","Action":"kms:Sign","Resource":"$KEY","Condition":{"StringEquals":{"kms:SigningAlgorithm":"ML_DSA_SHAKE_256"}}},
 {"Sid":"ReadIssuingPublicKey","Effect":"Allow","Action":["kms:GetPublicKey","kms:DescribeKey"],"Resource":"$KEY"}]}
J
aws iam create-role --role-name lattice-ca-signer --assume-role-policy-document file://trust.json --description "Lattice VPN signing service: may sign with the issuing CA key and nothing else" --query Role.Arn --output text 2>&1 | tail -1
aws iam put-role-policy --role-name lattice-ca-signer --policy-name sign-with-issuing-key --policy-document file://policy.json && echo policy-attached
aws iam create-instance-profile --instance-profile-name lattice-ca-signer --query InstanceProfile.Arn --output text 2>&1 | tail -1
aws iam add-role-to-instance-profile --instance-profile-name lattice-ca-signer --role-name lattice-ca-signer && echo profile-linked
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --group-name lattice-ca-signer --description "Lattice signing service: API server and admin only" --vpc-id $VPC --query GroupId --output text 2>&1 | tail -1); echo "security group: $SG"
MYIP=$(curl -s --max-time 8 https://checkip.amazonaws.com | tr -d '\n'); echo "admin address: $MYIP"
aws ec2 authorize-security-group-ingress --group-id $SG --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP/32,Description=admin-ssh-mac-mini}]" "IpProtocol=udp,FromPort=51821,ToPort=51821,IpRanges=[{CidrIp=5.78.203.171/32,Description=private-link-from-account-api}]" --query 'SecurityGroupRules[].[IpProtocol,FromPort,CidrIpv4]' --output text 2>&1 | tail -3
aws ec2 import-key-pair --key-name lattice-admin --public-key-material fileb://$HOME/.ssh/cloakvpn_ed25519.pub --query KeyFingerprint --output text 2>&1 | tail -1
echo "role policies: $(aws iam list-role-policies --role-name lattice-ca-signer --query PolicyNames --output text) | attached managed: $(aws iam list-attached-role-policies --role-name lattice-ca-signer --query 'length(AttachedPolicies)' --output text)"
