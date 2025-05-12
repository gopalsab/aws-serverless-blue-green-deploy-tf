provider "aws" {
  region = "us-east-1"
}

locals {
  lambda_zip_file = "${path.root}/../src/hello_lambda.zip"
}

# Base Lambda Function
module "lambda_function" {
  source          = "./modules/lambda_function"
  lambda_zip_file = local.lambda_zip_file
}

# Wait for version to be available
resource "time_sleep" "wait_for_version" {
  depends_on = [module.lambda_function]
  create_duration = "10s"
}

# Production Alias (Blue)
resource "aws_lambda_alias" "prod" {
  name             = "prod"
  description      = "Production alias"
  function_name    = module.lambda_function.function_name
  function_version = module.lambda_function.version
  depends_on       = [time_sleep.wait_for_version]
}

# Test Alias (Green)
resource "aws_lambda_alias" "test" {
  name             = "test"
  description      = "Test alias"
  function_name    = module.lambda_function.function_name
  function_version = module.lambda_function.version
  depends_on       = [time_sleep.wait_for_version]
}

# API Gateway
resource "aws_api_gateway_rest_api" "api" {
  name = "bg-deployment-api"
}

resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# API Gateway Integration for Test
resource "aws_api_gateway_integration" "test_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_alias.test.invoke_arn
}

# API Gateway Integration for Prod
resource "aws_api_gateway_integration" "prod_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_alias.prod.invoke_arn
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.test_integration,
    aws_api_gateway_integration.prod_integration
  ]
  rest_api_id = aws_api_gateway_rest_api.api.id
}

# API Gateway Stages
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id  = aws_api_gateway_rest_api.api.id
  stage_name   = "prod"
  
  variables = {
    alias = "prod"
  }
}

resource "aws_api_gateway_stage" "test" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id  = aws_api_gateway_rest_api.api.id
  stage_name   = "test"
  
  variables = {
    alias = "test"
  }
}

# Lambda Permission for Test Stage
resource "aws_lambda_permission" "test_permission" {
  statement_id  = "AllowAPIGatewayInvokeTest"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/GET/hello"
  qualifier     = "test"
}

# Lambda Permission for Prod Stage
resource "aws_lambda_permission" "prod_permission" {
  statement_id  = "AllowAPIGatewayInvokeProd"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/GET/hello"
  qualifier     = "prod"
}

# Variables
variable "prod_version" {
  description = "Production Lambda version"
  type        = string
  default     = "1"
}

variable "test_version" {
  description = "Test Lambda version"
  type        = string
  default     = "1"
}

# Outputs
output "lambda_version" {
  value = module.lambda_function.version
}

output "prod_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/hello"
}

output "test_url" {
  value = "${aws_api_gateway_stage.test.invoke_url}/hello"
}

output "prod_version" {
  value = aws_lambda_alias.prod.function_version
}

output "test_version" {
  value = aws_lambda_alias.test.function_version
}
output "api_id" {
  value = aws_api_gateway_rest_api.api.id
}
