variable "lambda_zip_file" {
  description = "Path to the Lambda zip file"
  type        = string
}

# IAM Role
resource "aws_iam_role" "lambda_role" {
  name = "lambda_bg_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Lambda Function
resource "aws_lambda_function" "lambda" {
  filename      = var.lambda_zip_file
  function_name = "hello-lambda"
  role         = aws_iam_role.lambda_role.arn
  handler      = "hello_lambda.lambda_handler"
  runtime      = "python3.9"
  publish      = true

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# Initial version publication
resource "null_resource" "publish_version" {
  triggers = {
    lambda_version = aws_lambda_function.lambda.version
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws lambda wait function-updated --function-name ${aws_lambda_function.lambda.function_name}
      VERSION=$(aws lambda publish-version \
        --function-name ${aws_lambda_function.lambda.function_name} \
        --query 'Version' \
        --output text)
      echo -n $VERSION > ${path.root}/initial_version.txt
    EOF
  }

  depends_on = [aws_lambda_function.lambda]
}


# Read initial version
data "local_file" "initial_version" {
  filename = "${path.root}/initial_version.txt"
  depends_on = [null_resource.publish_version]
}

output "function_name" {
  value = aws_lambda_function.lambda.function_name
}

output "function_arn" {
  value = aws_lambda_function.lambda.arn
}

output "version" {
  value = data.local_file.initial_version.content
}
