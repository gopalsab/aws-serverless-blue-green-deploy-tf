#!/bin/bash

cd ~/environment/bg-deployment

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Function to show current status
show_status() {
    echo -e "\n${BLUE}Current Configuration:${NC}"
    
    cd terraform || exit 1
    
    # Get version numbers
    CURRENT_VERSION=$(aws lambda list-versions-by-function --function-name hello-lambda --query 'Versions[-1].Version' --output text)
    PROD_VERSION=$(aws lambda get-alias --function-name hello-lambda --name prod --query 'FunctionVersion' --output text)
    TEST_VERSION=$(aws lambda get-alias --function-name hello-lambda --name test --query 'FunctionVersion' --output text)
    
    echo -e "Current Lambda version: ${GREEN}$CURRENT_VERSION${NC}"
    echo -e "Production version: ${GREEN}$PROD_VERSION${NC}"
    echo -e "Test version: ${GREEN}$TEST_VERSION${NC}"
    
    echo -e "\n${BLUE}Testing Endpoints:${NC}"
    echo -e "\nProduction URL (Blue):"
    curl -s "$(terraform output -raw prod_url)" | jq '.'
    echo -e "\nTest URL (Green):"
    curl -s "$(terraform output -raw test_url)" | jq '.'
    
    cd ..
}

# Function to deploy new version
deploy_new_version() {
    echo -e "${BLUE}Deploying new version to test environment...${NC}"
    
    # Create deployment package
    cd ~/environment/bg-deployment/src
    zip -r hello_lambda.zip hello_lambda.py
    cd ..
    
    # Get current production version
    cd terraform
    PROD_VERSION=$(aws lambda get-alias --function-name hello-lambda --name prod --query 'FunctionVersion' --output text)
    
    # Update Lambda code and publish new version
    NEW_VERSION=$(aws lambda update-function-code \
        --function-name hello-lambda \
        --zip-file fileb://../src/hello_lambda.zip \
        --publish \
        --query 'Version' \
        --output text)

    echo -e "${GREEN}Published version ${NEW_VERSION}${NC}"
    
    # Update only test alias to point to new version
    aws lambda update-alias \
        --function-name hello-lambda \
        --name test \
        --function-version $NEW_VERSION
    
    # Get API ID and resource ID
    API_ID=$(terraform output -raw api_id)
    RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[?path==`/hello`].id' --output text)
    
    # Update the API Gateway integration for test
    aws apigateway put-integration \
        --rest-api-id $API_ID \
        --resource-id $RESOURCE_ID \
        --http-method GET \
        --type AWS_PROXY \
        --integration-http-method POST \
        --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:$(aws sts get-caller-identity --query 'Account' --output text):function:hello-lambda:test/invocations
    
    # Create new deployment
    DEPLOYMENT_ID=$(aws apigateway create-deployment \
        --rest-api-id $API_ID \
        --stage-name test \
        --query 'id' \
        --output text)
    
    echo -e "${GREEN}Created new API Gateway deployment: ${DEPLOYMENT_ID}${NC}"
    
    # Update test stage to use new deployment
    aws apigateway update-stage \
        --rest-api-id $API_ID \
        --stage-name test \
        --patch-operations op=replace,path=/deploymentId,value=$DEPLOYMENT_ID
    
    # Update Terraform state for test alias
    terraform apply -auto-approve \
        -var "test_version=${NEW_VERSION}" \
        -var "prod_version=${PROD_VERSION}" \
        -target=aws_lambda_alias.test
    
    cd ..
    
    echo -e "${GREEN}Deployed version $NEW_VERSION to test stage${NC}"
    echo -e "${BLUE}Waiting for changes to propagate... (30s)${NC}"
    sleep 30
    
    show_status
}



# Function to promote to production
promote_to_prod() {
    echo -e "${BLUE}Promoting test version to production...${NC}"
    
    cd terraform
    TEST_VERSION=$(aws lambda get-alias --function-name hello-lambda --name test --query 'FunctionVersion' --output text)
    
    # Update production alias
    aws lambda update-alias \
        --function-name hello-lambda \
        --name prod \
        --function-version $TEST_VERSION
    
    # Get API ID and resource ID
    API_ID=$(terraform output -raw api_id)
    RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[?path==`/hello`].id' --output text)
    
    # Update the API Gateway integration for production
    aws apigateway put-integration \
        --rest-api-id $API_ID \
        --resource-id $RESOURCE_ID \
        --http-method GET \
        --type AWS_PROXY \
        --integration-http-method POST \
        --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:$(aws sts get-caller-identity --query 'Account' --output text):function:hello-lambda:prod/invocations
    
    # Create new deployment
    DEPLOYMENT_ID=$(aws apigateway create-deployment \
        --rest-api-id $API_ID \
        --stage-name prod \
        --query 'id' \
        --output text)
    
    echo -e "${GREEN}Created new API Gateway deployment: ${DEPLOYMENT_ID}${NC}"
    
    # Update production stage to use new deployment
    aws apigateway update-stage \
        --rest-api-id $API_ID \
        --stage-name prod \
        --patch-operations op=replace,path=/deploymentId,value=$DEPLOYMENT_ID
    
    # Update Terraform state for production alias
    terraform apply -auto-approve \
        -var "test_version=${TEST_VERSION}" \
        -var "prod_version=${TEST_VERSION}" \
        -target=aws_lambda_alias.prod
    
    cd ..
    
    echo -e "${GREEN}Production updated to version $TEST_VERSION${NC}"
    echo -e "${BLUE}Waiting for changes to propagate... (30s)${NC}"
    sleep 30
    
    show_status
}



# Main menu
while true; do
    echo -e "\n${BLUE}Blue/Green Deployment Management${NC}"
    echo "1) Deploy new version to test"
    echo "2) Show current status"
    echo "3) Promote test to production"
    echo "4) Exit"
    
    read -p "Select option (1-4): " choice
    
    case $choice in
        1)
            deploy_new_version
            ;;
        2)
            show_status
            ;;
        3)
            promote_to_prod
            ;;
        4)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
done
