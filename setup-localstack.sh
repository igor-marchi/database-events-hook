# #!/bin/bash

# Carregar variáveis de ambiente do arquivo .env
. "$(dirname "$0")/.env"

# Remove the /dist directory and /src/lambda.zip file if they exist
rm -rf dist
rm -f src/lambda.zip

# Create SQS queue
QUEUE_URL=$(awslocal sqs create-queue --queue-name payments.fifo --attributes FifoQueue=true --query 'QueueUrl' --output text)
echo "Created SQS queue with URL: $QUEUE_URL"

# Get SQS queue ARN
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
echo "SQS queue ARN: $QUEUE_ARN"

# Build the Lambda function
npm run build

# Create Lambda zip file without including the directory structure
zip -j src/lambda.zip dist/lambda.js

# Create Lambda function sqsConsumer
awslocal lambda create-function --function-name sqsConsumer \
  --runtime nodejs14.x \
  --handler lambda.handler \
  --zip-file fileb://src/lambda.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --environment Variables="{SQS_QUEUE_URL=$QUEUE_URL, DATABASE_URL=$DATABASE_URL, OPENSEARCH_NODE=$OPENSEARCH_NODE, AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY}"

# Create event source mapping sqsConsumer
awslocal lambda create-event-source-mapping \
  --function-name sqsConsumer \
  --batch-size 10 \
  --event-source-arn $QUEUE_ARN

# Create Lambda function apiGatewayHandler
awslocal lambda create-function --function-name apiGatewayHandler \
  --runtime nodejs14.x \
  --handler lambda.apiGatewayHandler \
  --zip-file fileb://src/lambda.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --environment Variables="{OPENSEARCH_NODE=$OPENSEARCH_NODE, AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY}"

# Criar API Gateway

# Variáveis
API_NAME="openSeachApiGateway"

echo "Criando API Gateway: $API_NAME"
API_ID=$(awslocal apigateway create-rest-api --name "$API_NAME" --query 'id' --output text)
echo "API criada com ID: $API_ID"

# Obter o ID do recurso raiz
ROOT_RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)
echo "ID do recurso raiz: $ROOT_RESOURCE_ID"

# Criar recurso '/search'
echo "Criando recurso '/search'"
RESOURCE_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_RESOURCE_ID" --path-part search --query 'id' --output text)
echo "Recurso '/search' criado com ID: $RESOURCE_ID"

# Adicionar método GET ao recurso '/search'
echo "Adicionando método GET ao recurso '/search'"
awslocal apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET --authorization-type "NONE"

# Configurar integração MOCK para o método GET
echo "Configurando integração MOCK para o método GET"
awslocal apigateway put-integration \
 --rest-api-id $API_ID \
 --resource-id $RESOURCE_ID \
 --http-method GET \
 --type AWS_PROXY \
 --integration-http-method POST \
 --uri arn:aws:apigateway:localstack:lambda:path/2015-03-31/functions/arn:aws:lambda:sa-east-1:000000000000:function:apiGatewayHandler/invocations


# Implantar a API
echo "Implantando a API no stage '$STAGE_NAME'"
awslocal apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE_NAME"

# Exibir endpoint de teste
ENDPOINT="http://localhost:4566/restapis/$API_ID/$STAGE_NAME/"
echo "API Gateway configurada com sucesso!"
echo "Teste o endpoint usando: curl $ENDPOINT"