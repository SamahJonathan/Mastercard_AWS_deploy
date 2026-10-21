# API de consumo de la capa Gold (HTTP API + Lambda). Autenticación por header x-api-key (valor en SSM).
resource "aws_apigatewayv2_api" "gold" {
  name          = "${local.name}-gold-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_methods = ["GET"]
    allow_origins = ["*"]
    allow_headers = ["x-api-key", "content-type"]
  }
}

resource "aws_apigatewayv2_integration" "gold" {
  api_id                 = aws_apigatewayv2_api.gold.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["api"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "gold" {
  api_id    = aws_apigatewayv2_api.gold.id
  route_key = "GET /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.gold.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.gold.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["api"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gold.execution_arn}/*/*"
}
