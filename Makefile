#export AWS_ACCESS_KEY_ID	 ?= $(shell aws configure get aws_access_key_id)
#export AWS_SECRET_ACCESS_KEY ?= $(shell aws configure get aws_secret_access_key)
export AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --output text --query 'Account')
export AWS_REGION		     = us-west-2
export GIT_REPO				 = appmesh
export EKSCTL_EXPERIMENTAL=true
export APPMESH_NS = appmesh-system

export CLUSTER_NAME = $(shell cat .id)-appmesh
export STACK_NAME = $(shell eksctl get nodegroup --cluster $(CLUSTER_NAME) -o json | jq -r '.[].StackName')
export INSTANCE_PROFILE_ARN = $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceProfileARN") | .OutputValue')
export ROLE_NAME = $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InstanceRoleARN") | .OutputValue' | cut -f2 -d/)

.id:
	git config user.email | awk -F@ '{print $$1}' > .id

deploy/cluster.yaml: .id deploy/cluster.yaml.in
	sed "s/{{ .Name }}/`cat .id`/g; s/{{ .Region }}/$(AWS_REGION)/g" deploy/cluster.yaml.in > $@

eks-deploy: deploy/cluster.yaml
	eksctl create cluster -f deploy/cluster.yaml

cluster: eks-deploy
	aws eks update-kubeconfig --name $(shell cat .id)-appmesh
	make -C falco deploy
	@echo 'Done with build cluster'

log/fluentbit/eks-fluentbit-configmap.yaml: log/fluentbit/eks-fluentbit-configmap.yaml.in
	sed "s/{{ .Region }}/$(AWS_REGION)/g; s/{{ .Eks-log-stream }}/$(CLUSTER_NAME)-log-stream/g" log/fluentbit/eks-fluentbit-configmap.yaml.in > $@

log/firehose/firehose-delivery-policy.json: log/firehose/firehose-delivery-policy.json.in
	sed "s/{{ .Account }}/$(AWS_ACCOUNT)/g; s/{{ .Region }}/$(AWS_REGION)/g; s/{{ .Eks-log-stream }}/$(CLUSTER_NAME)-log-stream/g; s/{{ .LogBucket }}/$(CLUSTER_NAME)-log/g" log/firehose/firehose-delivery-policy.json.in > $@

firehose: log/firehose/firehose-delivery-policy.json
	aws iam create-role \
		--role-name $(CLUSTER_NAME)-firehose_delivery_role \
		--assume-role-policy-document file://log/firehose/firehose-policy.json > /dev/null

	aws iam put-role-policy \
		--role-name $(CLUSTER_NAME)-firehose_delivery_role \
		--policy-name $(CLUSTER_NAME)-firehose-fluentbit-s3-streaming \
		--policy-document file://log/firehose/firehose-delivery-policy.json > /dev/null

	aws s3 mb s3://$(CLUSTER_NAME)-log
	# Found it takes some time for the role to be setup and following stream will fail
	sleep 10; aws firehose create-delivery-stream \
	  --delivery-stream-name $(CLUSTER_NAME)-log-stream \
	  --delivery-stream-type DirectPut \
	  --s3-destination-configuration RoleARN=arn:aws:iam::$(AWS_ACCOUNT):role/$(CLUSTER_NAME)-firehose_delivery_role,BucketARN="arn:aws:s3:::$(CLUSTER_NAME)-log",Prefix=eks > /dev/null
	@echo "Done setting up FireHose"


logs: log/fluentbit/eks-fluentbit-configmap.yaml
#	aws iam put-role-policy \
#        --role-name $(ROLE_NAME) \
#        --policy-name $(CLUSTER_NAME)-FluentBit-DS \
#        --policy-document file://log/eks-fluentbit-daemonset-policy.json > /dev/null

	kubectl apply -k log/fluentbit/.

repo:
	eksctl enable repo \
		--cluster $(shell cat .id)-appmesh \
		--region $(AWS_REGION) --git-user fluxcd \
		--git-email $(shell cat .id)@users.noreply.github.com \
		--git-url git@github.com:$(shell cat .id)/$(GIT_REPO)

mesh:
	eksctl enable profile appmesh \
		--revision=demo \
		--cluster $(shell cat .id)-appmesh \
		--region $(AWS_REGION) --git-user fluxcd \
		--git-email $(shell cat .id)@users.noreply.github.com \
		--git-url git@github.com:$(shell cat .id)/$(GIT_REPO)
	# Flux does a git-cluster reconciliation every five minutes,
	# the following command can be used to speed up the synchronization.
	fluxctl sync --k8s-fwd-ns flux

status:
	# kubectl get --watch helmreleases --all-namespaces
	kubectl get helmreleases --all-namespaces
	kubectl describe mesh

mesh-logs:
	 kubectl logs -n $(APPMESH_NS) -f --since 10s $(shell kubectl get pods -n $(APPMESH_NS) -o name | grep controller)

update-kube-config:
	aws eks update-kubeconfig --name $(shell cat .id)-appmesh

clean:
	# Stop Firehose
#	aws firehose delete-delivery-stream --delivery-stream-name $(CLUSTER_NAME)-log-stream > /dev/null
#	aws iam delete-role-policy --policy-name $(CLUSTER_NAME)-firehose-fluentbit-s3-streaming \
#		--role-name $(CLUSTER_NAME)-firehose_delivery_role> /dev/null
#	aws iam delete-role --role-name $(CLUSTER_NAME)-firehose_delivery_role > /dev/null

#	aws iam delete-role-policy \
#		--role-name $(ROLE_NAME) \
#		--policy-name $(CLUSTER_NAME)-FluentBit-DS > /dev/null

	# Delete all data in S3 Bucket and then remove bucket...
	# aws s3 rm s3://$(CLUSTER_NAME)-log
	 eksctl delete cluster --name $(shell cat .id)-appmesh --region $(AWS_REGION)
