#!/usr/bin/bash 
Green='\033[0;32m'
Red='\033[0;31m'
NC='\033[0m'

if [ -z "$1" ]
then
    infra_env='dev'
else
    infra_env=$1
fi  

if [ $infra_env != "dev" -a $infra_env != "qa" -a $infra_env != "sandbox" ]
then
    echo "Environment name can only be dev or qa or sandbox. example 'sh creator.sh dev' "
    exit 1
fi
echo "Environment: $infra_env"

deployment_region=$(curl -s http://169.254.169.254/task/AvailabilityZone | sed 's/\(.*\)[a-z]/\1/')
echo "Region: $deployment_region "
echo '*************************************************************'
echo ' '

echo '*************************************************************'
echo ' '

# if [ -z "$2" ]
# then
#     echo "Region not passed. Defaulting to us-east-1"
#     deployment_region='us-east-1'
# else
#     deployment_region=$2
# fi

printf "$Green Please enter your LLM choice (1/2/3/4/5/6/7): $NC"
printf "\n"
options=("Amazon Bedrock" "Llama2-7B" "Llama2-13B" "Llama2-70B" "Falcon-7B" "Falcon-40B" "Falcon-180B" "Quit")
model_id='meta-textgeneration-llama-2-7b-f'
instance_type='ml.g5.2xlarge'
select opt in "${options[@]}"
do
    case $opt in
        "Amazon Bedrock")
            instance_type='Serverless'
            model_id='Amazon Bedrock'
            ;;
        "Llama2-7B")
            instance_type='ml.g5.2xlarge'
            model_id='meta-textgeneration-llama-2-7b-f'
            ;;
        "Llama2-13B")
            instance_type='ml.g5.12xlarge'
            model_id='meta-textgeneration-llama-2-13b-f'
            ;;
        "Llama2-70B")
            instance_type='ml.g5.48xlarge'
            model_id='meta-textgeneration-llama-2-70b-f'
            ;;
        "Falcon-7B")
            instance_type='ml.g5.2xlarge'
            model_id='huggingface-llm-falcon-7b-bf16'
            ;;
        "Falcon-40B")
            instance_type='ml.g5.12xlarge'
            model_id='huggingface-llm-falcon-40b-bf16'
            ;;
        "Falcon-180B")
            instance_type='ml.p4de.24xlarge'
            model_id='huggingface-llm-falcon-180b-bf16'
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
    break
done

echo '*************************************************************'
echo ' '

if [ "$opt" != "Amazon Bedrock" ]
then
    printf  "$Red !!! Attention The $opt model will be deployed on $instance_type . Check Service Quotas to apply for limit increase $NC"
    
else
    printf "$Green Enter a custom secret API Key(atleast 20 Characters long) to secure access to Bedrock APIs $NC"
    read secret_api_key
    secret_len=${#secret_api_key}

    if [ $secret_len -lt 20 ]
    then
        printf "$Red Secret Cannot be less than 20 characters. \n Exit \n $NC"
        exit
    fi

    echo ' '
    echo '*************************************************************'
    echo ' '
    printf "$Red !!! Attention Provisioning $model_id infrastructure. Please ensure you have access to models in $opt $NC"
fi
echo ' '
echo '*************************************************************'
echo ' '
printf "$Green Press Enter to proceed with deployment else ctrl+c to cancel $NC "
read -p " "

cd ..
echo "--- Upgrading npm ---"
sudo npm install n stable -g
echo "--- Installing cdk ---"
sudo npm install -g aws-cdk@2.91.0

echo "--- Bootstrapping CDK on account in region $deployment_region ---"
cdk bootstrap aws://$(aws sts get-caller-identity --query "Account" --output text)/$deployment_region

cd serverless-rag-demo
echo "--- pip install requirements ---"
python3 -m pip install -r requirements.txt

echo "--- CDK synthesize ---"
cdk synth -c environment_name=$infra_env -c current_timestamp=$CURRENT_UTC_TIMESTAMP -c llm_model_id="$model_id" -c secret_api_key=$secret_api_key

echo "--- CDK deploy ---"
CURRENT_UTC_TIMESTAMP=$(date -u +"%Y%m%d%H%M%S")
echo Setting Tagging Lambda Image with timestamp $CURRENT_UTC_TIMESTAMP
cdk deploy -c environment_name=$infra_env -c current_timestamp=$CURRENT_UTC_TIMESTAMP -c llm_model_id="$model_id" -c secret_api_key="$secret_api_key" LlmsWithServerlessRag"$infra_env"Stack --require-approval never
echo "--- Get Build Container ---"
project=lambdaragllmcontainer"$infra_env"
echo project: $project
build_container=$(aws codebuild list-projects|grep -o $project'[^,"]*')
echo container: $build_container
echo "--- Trigger Build ---"
BUILD_ID=$(aws codebuild start-build --project-name $build_container | jq '.build.id' -r)
echo Build ID : $BUILD_ID
if [ "$?" != "0" ]; then
    echo "Could not start CodeBuild project. Exiting."
    exit 1
else
    echo "Build started successfully."
fi

echo "Check build status every 30 seconds. Wait for codebuild to finish"
j=0
while [ $j -lt 50 ];
do 
    sleep 30
    echo 'Wait for 30 seconds. Build job typically takes 15 minutes to complete...'
    build_status=$(aws codebuild batch-get-builds --ids $BUILD_ID | jq -cs '.[0]["builds"][0]["buildStatus"]')
    build_status="${build_status%\"}"
    build_status="${build_status#\"}"
    if [ $build_status = "SUCCEEDED" ] || [ $build_status = "FAILED" ] || [ $build_status = "STOPPED" ]
    then
        echo "Build complete: $latest_build : status $build_status"
        break
    fi
    ((j++))
done

if [ $build_status = "SUCCEEDED" ]
then
    COLLECTION_NAME=$(jq '.context.'$infra_env'.collection_name' cdk.json -r)
    COLLECTION_ENDPOINT=$(aws opensearchserverless batch-get-collection --names $COLLECTION_NAME |jq '.collectionDetails[0]["collectionEndpoint"]' -r)
    
    if [ "$opt" = "Amazon Bedrock" ]
    then
        CHAT_COLLECTION_NAME=$(jq '.context.'$infra_env'.chat_collection_name' cdk.json -r)
        CHAT_COLLECTION_ENDPOINT=$(aws opensearchserverless batch-get-collection --names $CHAT_COLLECTION_NAME |jq '.collectionDetails[0]["collectionEndpoint"]' -r)
        cdk deploy -c environment_name=$infra_env -c chat_collection_endpoint=$CHAT_COLLECTION_ENDPOINT -c collection_endpoint=$COLLECTION_ENDPOINT -c current_timestamp=$CURRENT_UTC_TIMESTAMP -c llm_model_id="$model_id" -c secret_api_key=$secret_api_key ApiGwLlmsLambda"$infra_env"Stack --require-approval never
    else
        cdk deploy -c environment_name=$infra_env -c chat_collection_endpoint=https://dummy-endpoint.amazonaws.com  -c collection_endpoint=$COLLECTION_ENDPOINT -c current_timestamp=$CURRENT_UTC_TIMESTAMP -c llm_model_id="$model_id" -c secret_api_key=$secret_api_key ApiGwLlmsLambda"$infra_env"Stack --require-approval never
    fi

    if [ "$opt" != "Amazon Bedrock" ]
    then
        cdk deploy -c environment_name=$infra_env -c llm_model_id="$model_id" SagemakerLlmdevStack --require-approval never
        echo "--- Get Sagemaker Deployment Container ---"
        project=sagemakerdeploy"$infra_env"
        build_container=$(aws codebuild list-projects|grep -o $project'[^,"]*')
        echo container: $build_container
        echo "--- Trigger Build ---"
        BUILD_ID=$(aws codebuild start-build --project-name $build_container | jq '.build.id' -r)
        echo Build ID : $BUILD_ID
        if [ "$?" != "0" ]; then
            echo "Could not start Sagemaker CodeBuild project. Exiting."
            exit 1
        else
            echo "Build started successfully."
            echo "Check Sagemaker Model deployment status every 30 seconds. Wait for codebuild to finish."
            j=0
            while [ $j -lt 500 ];
            do 
                sleep 30
                echo 'Wait for 30 seconds. Build job typically takes 20 minutes to complete...'
                build_status=$(aws codebuild batch-get-builds --ids $BUILD_ID | jq -cs '.[0]["builds"][0]["buildStatus"]')
                build_status="${build_status%\"}"
                build_status="${build_status#\"}"
                if [ $build_status = "SUCCEEDED" ] || [ $build_status = "FAILED" ] || [ $build_status = "STOPPED" ]
                then
                    echo "Sagemaker deployment complete: $latest_build : status $build_status"
                    break
                fi
                ((j++))
            done
            fi
    
    fi
else
    echo "Exiting. Build did not succeed."
fi

echo "Deployment Complete"
